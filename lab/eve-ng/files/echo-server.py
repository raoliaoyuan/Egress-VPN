#!/usr/bin/env python3
"""回显服务：把看到的来源地址，以及它从凭证认出的调用方身份，以 JSON 返回。
用法：echo-server.py <服务名> [--cert 证书 --key 私钥] [--client-ca 客户端CA] [--tokens 令牌表]

端口：
- 80、8080：HTTP。实验里 Egress 对 80 做七层处理，8080 按四层转发。
- 8443：HTTPS（给了 --cert、--key 时）。
- 9443：HTTPS，并且要求客户端证书（另外给了 --client-ca 时）。身份取自证书的 CN。

凭证的两种形式：
- 请求头 x-egress-credential 里的令牌。服务只保存令牌的 SHA-256（--tokens 指向的文件，每行“摘要 身份”），
  认得出就返回对应的身份，认不出返回 unknown。响应里不带令牌本身。
- 客户端证书。私钥不在线路上传输，服务想回显也回显不出来。

/reflect 把收到的请求头原样放进响应，TRACE 方法按 HTTP 的定义回显整个请求。
它们代表“服务端会把请求内容带回来”的情况（调试接口、错误页），实验用来演示令牌这种凭证的固有限制。
"""
import argparse
import hashlib
import json
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser()
ap.add_argument("name")
ap.add_argument("--cert")
ap.add_argument("--key")
ap.add_argument("--client-ca")
ap.add_argument("--tokens")
ARGS = ap.parse_args()
HEADER = "x-egress-credential"


def identities():
    """每次请求都重新读令牌表，改了不用重启服务。"""
    table = {}
    if ARGS.tokens:
        try:
            for line in open(ARGS.tokens):
                parts = line.split()
                if len(parts) == 2:
                    table[parts[0]] = parts[1]
        except OSError:
            pass
    return table


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    # 空闲的长连接 30 秒后关闭。主备切换时，旧网关那一侧的连接不会正常关闭，没有这个超时它们会一直占着线程。
    timeout = 30

    def reply(self, body, ctype="application/json"):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        tls = isinstance(self.connection, ssl.SSLSocket)
        token = self.headers.get(HEADER)
        identity = None
        if token is not None:
            identity = identities().get(hashlib.sha256(token.encode()).hexdigest(), "unknown")
        cert_cn = None
        if tls:
            for rdn in (self.connection.getpeercert() or {}).get("subject", ()):
                for key, value in rdn:
                    if key == "commonName":
                        cert_cn = value
        out = {
            "server": ARGS.name,
            "client": self.client_address[0],
            "tls": tls,
            "identity": identity,
            "client_cert": cert_cn,
            "path": self.path,
        }
        if self.path.startswith("/reflect"):
            out["headers"] = dict(self.headers.items())
        self.reply(json.dumps(out).encode())

    def do_TRACE(self):
        lines = [self.requestline] + [f"{k}: {v}" for k, v in self.headers.items()]
        self.reply(("\r\n".join(lines) + "\r\n\r\n").encode(), "message/http")

    def log_message(self, *args):
        pass


def serve(port, ctx=None):
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    if ctx:
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()


def tls_context(require_client_cert):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(ARGS.cert, ARGS.key)
    if require_client_cert:
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.load_verify_locations(ARGS.client_ca)
    return ctx


if ARGS.cert:
    threading.Thread(target=serve, args=(8443, tls_context(False)), daemon=True).start()
    if ARGS.client_ca:
        threading.Thread(target=serve, args=(9443, tls_context(True)), daemon=True).start()
threading.Thread(target=serve, args=(8080,), daemon=True).start()
serve(80)
