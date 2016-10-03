# -*- coding: utf-8 -*-
import gzip
import httplib
import re
import select
import socket
import ssl
import sys
import threading
import urlparse
import zlib
from BaseHTTPServer import HTTPServer, BaseHTTPRequestHandler
from SocketServer import ThreadingMixIn
from cStringIO import StringIO

from logger import log


class ThreadingProxyServer(ThreadingMixIn, HTTPServer):
    address_family = socket.AF_INET
    daemon_threads = True

    def handle_error(self, request, client_address):
        # surpress socket/ssl related errors
        cls, e = sys.exc_info()[:2]
        if cls is socket.error or cls is ssl.SSLError:
            pass
        else:
            return HTTPServer.handle_error(self, request, client_address)


# noinspection PyAttributeOutsideInit,PyBroadException
class ProxyRequestHandler(BaseHTTPRequestHandler):
    timeout = 5

    forwardProxyHost = None
    forwardProxyPort = None

    protocol_version = "HTTP/1.1"

    def __init__(self, request, client_address, server):
        self.tls = threading.local()
        self.tls.conns = {}
        BaseHTTPRequestHandler.__init__(self, request, client_address, server)

    # noinspection PyShadowingBuiltins
    def log_error(self, format, *args):
        # surpress "Request timed out: timeout('timed out',)"
        if isinstance(args[0], socket.timeout):
            return
        log.error(format, *args)

    def do_CONNECT(self):
        self.connect_relay()

    def connect_relay(self):
        address = self.path.split(':', 1)
        address[1] = int(address[1]) or 443
        try:
            s = socket.create_connection(address, timeout=self.timeout)
        except Exception as _:
            self.send_error(502)
            return
        self.send_response(200, 'Connection Established')
        self.end_headers()

        conns = [self.connection, s]
        self.close_connection = 0
        while not self.close_connection:
            rlist, wlist, xlist = select.select(conns, [], conns, self.timeout)
            if xlist or not rlist:
                break
            for r in rlist:
                other = conns[1] if r is conns[0] else conns[0]
                data = r.recv(16384)
                if not data:
                    self.close_connection = 1
                    break
                other.sendall(data)

    # noinspection PyNoneFunctionAssignment,PyTypeChecker
    def do_GET(self):
        req = self
        content_length = int(req.headers.get('Content-Length', 0))
        req_body = self.rfile.read(content_length) if content_length else None

        if req.path[0] == '/':
            if isinstance(self.connection, ssl.SSLSocket):
                req.path = "https://%s%s" % (req.headers['Host'], req.path)
            else:
                req.path = "http://%s%s" % (req.headers['Host'], req.path)

        u = urlparse.urlsplit(req.path)
        scheme, netloc, path = u.scheme, u.netloc, (u.path + '?' + u.query if u.query else u.path)
        assert scheme in ('http', 'https')
        if netloc:
            req.headers['Host'] = netloc
        setattr(req, 'headers', self.filter_headers(req.headers))

        log.info("Request: %s", self.path)

        origin = None
        try:
            origin = (scheme, netloc)
            if origin not in self.tls.conns:
                if scheme == 'https':
                    if self.forwardProxyHost and self.forwardProxyPort:
                        self.tls.conns[origin] = httplib.HTTPSConnection(self.forwardProxyHost,
                                                                         self.forwardProxyPort,
                                                                         timeout=self.timeout)
                    else:
                        self.tls.conns[origin] = httplib.HTTPSConnection(netloc, timeout=self.timeout)
                else:
                    if self.forwardProxyHost and self.forwardProxyPort:
                        self.tls.conns[origin] = httplib.HTTPConnection(self.forwardProxyHost,
                                                                        self.forwardProxyPort,
                                                                        timeout=self.timeout)
                    else:
                        self.tls.conns[origin] = httplib.HTTPConnection(netloc, timeout=self.timeout)

            conn = self.tls.conns[origin]
            conn.request(self.command,
                         self.path if self.forwardProxyHost and self.forwardProxyPort
                         else path, req_body, dict(req.headers))
            res = conn.getresponse()
            res_body = res.read()
        except Exception as e:
            if origin in self.tls.conns:
                del self.tls.conns[origin]
            self.send_error(502, e.message)
            return

        version_table = {10: 'HTTP/1.0', 11: 'HTTP/1.1'}
        setattr(res, 'headers', res.msg)
        setattr(res, 'response_version', version_table[res.version])

        setattr(res, 'headers', self.filter_headers(res.headers))

        self.wfile.write("%s %d %s\r\n" % (self.protocol_version, res.status, res.reason))
        for line in res.headers.headers:
            self.wfile.write(line)
        self.end_headers()
        self.wfile.write(res_body)
        self.wfile.flush()

    do_HEAD = do_GET
    do_POST = do_GET
    do_OPTIONS = do_GET

    def filter_headers(self, headers):
        # http://tools.ietf.org/html/rfc2616#section-13.5.1
        hop_by_hop = (
            'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailers',
            'transfer-encoding', 'upgrade')
        for k in hop_by_hop:
            del headers[k]

        # accept only supported encodings
        if 'Accept-Encoding' in headers:
            ae = headers['Accept-Encoding']
            filtered_encodings = [x for x in re.split(r',\s*', ae) if x in ('identity', 'gzip', 'x-gzip', 'deflate')]
            headers['Accept-Encoding'] = ', '.join(filtered_encodings)

        return headers

    def encode_content_body(self, text, encoding):
        if encoding == 'identity' or encoding == 'text':
            data = text
        elif encoding in ('gzip', 'x-gzip'):
            io = StringIO()
            with gzip.GzipFile(fileobj=io, mode='wb') as f:
                f.write(text)
            data = io.getvalue()
        elif encoding == 'deflate':
            data = zlib.compress(text)
        else:
            raise Exception("Unknown Content-Encoding: %s" % encoding)
        return data

    def decode_content_body(self, data, encoding):
        if encoding == 'identity' or encoding == 'text':
            text = data
        elif encoding in ('gzip', 'x-gzip'):
            io = StringIO(data)
            with gzip.GzipFile(fileobj=io) as f:
                text = f.read()
        elif encoding == 'deflate':
            try:
                text = zlib.decompress(data)
            except zlib.error:
                text = zlib.decompress(data, -zlib.MAX_WBITS)
        else:
            raise Exception("Unknown Content-Encoding: %s" % encoding)
        return text

    def log_request(self, code='-', size='-'):
        log.info("Request: %s", self.path)


def main():
    import sys

    # Start proxy server
    server_address = (sys.argv[1] if len(sys.argv) > 1 else '0.0.0.0', int(sys.argv[2]) if len(sys.argv) > 2 else 8080)
    httpd = ThreadingProxyServer(server_address, ProxyRequestHandler)
    # Start main loop
    sa = httpd.socket.getsockname()
    print "VPN proxy started on", sa[0], "port", sa[1], "..."
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print ""
    finally:
        print "Stopping VPN proxy..."
        httpd.shutdown()
        exit()

if __name__ == '__main__':
    main()
