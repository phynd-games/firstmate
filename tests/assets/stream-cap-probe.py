#!/usr/bin/env python3
"""Hold N dashboard stream clients open, then report what the next one gets.

Backpressure is a bound, so proving it needs the cap held deterministically
rather than by racing background processes into the socket.
"""
import socket
import sys
import time
import urllib.error
import urllib.request

port = int(sys.argv[1])
want = int(sys.argv[2])
socks = []
try:
    for _ in range(want):
        s = socket.create_connection(("127.0.0.1", port), timeout=5)
        s.sendall(b"GET /api/v1/stream HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        s.recv(64)  # block until this client is actually being served
        socks.append(s)
    time.sleep(0.3)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open("http://127.0.0.1:%d/api/v1/stream" % port, timeout=5) as r:
            print(r.status)
    except urllib.error.HTTPError as exc:
        print(exc.code)
finally:
    for s in socks:
        s.close()
