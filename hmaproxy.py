#!/usr/bin/env python
# -*- coding: utf-8 -*-
import httplib
import ssl
import urlparse

from logger import log
from proxy import ProxyRequestHandler, ThreadingProxyServer
from conf import *
from Queue import Queue, Empty
from threading import Thread
import os
from time import time, sleep

end = False

HMA_CHANGE_IP_INTERVAL = int(os.getenv('HMA_CHANGE_IP_INTERVAL', 60))  # change IP interval
lastChangedVPNNum = 0
lastChangedVPNTime = time()


def changeIP(proxyNum):
    global lastChangedVPNNum, lastChangedVPNTime
    os.system('/opt/ip-changer.sh change %i' % (proxyNum + 1))
    lastChangedVPNNum = proxyNum
    lastChangedVPNTime = time()


class IPChangerThread(Thread):
    def __init__(self):
        super(IPChangerThread, self).__init__()
        self.daemon = True
        self.start()

    def run(self):
        interval = HMA_CHANGE_IP_INTERVAL / 2
        super(IPChangerThread, self).run()
        while not end:
            now = time()
            if now - lastChangedVPNTime > interval:
                changeIP((lastChangedVPNNum + 1) % 2)
            sleep(1)


class RequestHandler(ProxyRequestHandler):
    @staticmethod
    def forwardThread(queue, proxyNum, path, command, req, req_body):
        resObj = {
            'errorCode': 0,
            'errorMessage': None,
            'res': None,
            'res_body': None,
            'proxyNum': proxyNum,
        }
        try:
            proxy = PROXIES[proxyNum]
            resObj['proxy'] = proxy

            _proxy = proxy.split(':')
            proxyHost = _proxy[0]
            proxyPort = _proxy[1]

            if path.startswith('https://'):
                conn = httplib.HTTPSConnection(proxyHost, proxyPort, timeout=TIMEOUT)
            else:
                conn = httplib.HTTPConnection(proxyHost, proxyPort, timeout=TIMEOUT)

            conn.request(command, path, req_body, dict(req.headers))
            res = conn.getresponse()
            res_body = res.read()

            if res:
                resObj['res'] = res
                resObj['res_body'] = res_body
                if res.status > 400:
                    resObj['errorCode'] = res.status
                    resObj['errorMessage'] = res.reason
                    log.debug('Proxy error: %s Error: %i %s', proxy, res.status, res.reason)
            else:
                resObj['errorCode'] = 501
                resObj['errorMessage'] = 'Unknown error!'

        except Exception as e:
            resObj['errorCode'] = 501
            resObj['errorMessage'] = e.message

        if resObj['errorCode'] in (403, 407, 429, 501, 502):
            changeIP(proxyNum)

        queue.put(resObj)

    # noinspection PyBroadException
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

        if scheme not in ('http', 'https'):
            return self.send_error(502, "Unsupported scheme: %s" % scheme)

        if netloc:
            req.headers['Host'] = netloc
        setattr(req, 'headers', self.filter_headers(req.headers))

        # Start threads on different proxies
        queue = Queue()
        for proxyNum in range(2):
            thread = Thread(target=RequestHandler.forwardThread,
                            args=(queue, proxyNum, self.path, self.command, req, req_body))
            thread.daemon = True
            thread.start()

        resObject = None
        res_body = res = None
        for _ in range(2):
            try:
                resObject = queue.get(timeout=TIMEOUT)
                if resObject['errorCode'] == 0:
                    res = resObject['res']
                    res_body = resObject['res_body']
                    break

            except Empty:
                resObject = {'errorCode': 408, 'errorMessage': 'Timeout!'}
                break

        # If all of them returns with error :-/
        if resObject['errorCode'] >= 500 or resObject['errorCode'] == 408:  # Error
            return self.send_error(resObject['errorCode'], resObject['errorMessage'])

        log.info('Proxy: %s | Request: %s', resObject['proxy'], self.path)

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

    def send_error(self, code, message=None):
        log.error("Error occured: %i %s", code, message)


# Start IP changer thread
ipChanger = IPChangerThread()

# Start proxy server
server_address = (HOST, PORT)
# noinspection PyRedeclaration
httpd = ThreadingProxyServer(server_address, RequestHandler)

# Start main loop
sa = httpd.socket.getsockname()
print "HMA proxy started on", sa[0], "port", sa[1], "..."
try:
    httpd.serve_forever()
except KeyboardInterrupt:
    print ""
finally:
    print "Stopping HMA proxy..."
    end = True
    httpd.shutdown()
    exit()
