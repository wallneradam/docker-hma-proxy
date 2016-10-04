#!/usr/bin/env python
# -*- coding: utf-8 -*-
import httplib
import ssl
import urlparse
from socket import timeout

import sys

from logger import log
from proxy import ProxyRequestHandler, ThreadingProxyServer
from conf import *
from Queue import Queue, Empty
from threading import Thread, Lock
import os
from time import time, sleep

end = False

HMA_CHANGE_IP_INTERVAL = int(os.getenv('HMA_CHANGE_IP_INTERVAL', 60))  # change IP interval
lastChangedVPNNum = 0
lastChangedVPNTime = time()
ipVersion = 0
_changeIPLock = Lock()


def changeIP(proxyNum, version):
    global lastChangedVPNNum, lastChangedVPNTime, ipVersion, _changeIPLock
    _changeIPLock.acquire()
    if version >= ipVersion:
        ipVersion += 1
        os.system('/opt/ip-changer.sh change %i' % (proxyNum + 1))
        lastChangedVPNNum = proxyNum
        lastChangedVPNTime = time()
    _changeIPLock.release()


class IPChangerThread(Thread):
    def __init__(self):
        super(IPChangerThread, self).__init__()
        self.daemon = True
        self.start()

    def run(self):
        interval = HMA_CHANGE_IP_INTERVAL
        super(IPChangerThread, self).run()
        while not end:
            now = time()
            if now - lastChangedVPNTime > interval:
                changeIP((lastChangedVPNNum + 1) % 2, sys.maxint)
            sleep(1)


class RequestHandler(ProxyRequestHandler):
    @staticmethod
    def forwardThread(queue, proxyNum, path, command, req, req_body):
        proxy = PROXIES[proxyNum]
        resObj = {
            'status': 0,
            'errorMessage': None,
            'res': None,
            'res_body': None,
            'proxyNum': proxyNum,
            'proxy': proxy
        }

        retry = RETRY
        timeoutRetry = RETRY_TIMEOUT
        while retry > 0 and timeoutRetry > 0:
            try:
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
                        resObj['status'] = res.status
                        resObj['errorMessage'] = res.reason
                else:
                    resObj['status'] = 501
                    resObj['errorMessage'] = 'Unknown error!'

                break

            except timeout:
                timeoutRetry -= 1
                resObj['status'] = 408
                resObj['errorMessage'] = 'VPN timeout!'

            except Exception as e:
                resObj['status'] = 501
                resObj['errorMessage'] = e.message if e.message else 'Unknown error! (exception)'
                retry -= 1
                sleep(RETRY_WAIT)

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
            return self.send_error(501, "Unsupported scheme: %s" % scheme)

        if netloc:
            req.headers['Host'] = netloc
        setattr(req, 'headers', self.filter_headers(req.headers))

        # Prevent multiple IP changes on failed requests
        startIpVersion = ipVersion

        # Start threads on different proxies
        queue = Queue()
        for proxyNum in range(2):
            thread = Thread(target=RequestHandler.forwardThread,
                            args=(queue, proxyNum, self.path, self.command, req, req_body))
            thread.daemon = True
            thread.start()

        resObj = None
        res_body = res = None
        for proxyNum in range(2):
            try:
                resObj = queue.get(timeout=TIMEOUT)
                res = resObj['res']
                res_body = resObj['res_body']
                if resObj['status'] == 0:
                    break

            except Empty:
                if not resObj:
                    resObj = {'status': 408, 'errorMessage': 'Timeout!', 'proxyNum': proxyNum}
                break

        if resObj['status'] in (403, 407, 408, 429, 500, 501, 502):
            changeIP(resObj['proxyNum'], startIpVersion)

        # If all of them returns with error :-/
        if resObj['status'] >= 500 or resObj['status'] in (408, 429):  # Error
            return self.send_error(resObj['status'], resObj['errorMessage'])

        log.info('Proxy: %i | Status: %i | Request: %s', resObj['proxyNum'] + 1,
                 res.status if res else resObj['status'], self.path)
        if not res:
            return self.send_error(501, 'Unknown error!')

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
        log.error("Error occured: %i %s - Request: %s", code, message, self.path)


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
