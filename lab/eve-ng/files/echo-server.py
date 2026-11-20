#!/usr/bin/env python3
"""回显服务：把看到的来源地址和 Egress 注入的凭证头以 JSON 返回。
用法：echo-server.py <服务名> [证书 私钥]
80 和 8080 端口提供 HTTP；给了证书和私钥时，另在 8443 端口提供 HTTPS。
实验里 Egress 把 80 和 8443 按 HTTP 处理、其余端口按四层转发，所以 8080 用来走四层这条路。
"""
import json
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAME = sys.argv[1]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        body = json.dumps({
            "server": NAME,
            "client": self.client_address[0],
            "tls": isinstance(self.connection, ssl.SSLSocket),
            "credential": self.headers.get("x-egress-credential"),
            "path": self.path,
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def serve(port, ctx=None):
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    if ctx:
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()


if len(sys.argv) > 3:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(sys.argv[2], sys.argv[3])
    threading.Thread(target=serve, args=(8443, ctx), daemon=True).start()
threading.Thread(target=serve, args=(8080,), daemon=True).start()
serve(80)
