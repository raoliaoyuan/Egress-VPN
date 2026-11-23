#!/usr/bin/env python3
"""回显服务：把看到的来源地址，以及它从凭证认出的调用方身份，以 JSON 返回。
用法：echo-server.py <服务名> [--cert 证书 --key 私钥] [--client-ca 客户端CA] [--tokens 凭证表]

端口：
- 80、8080、8081：HTTP。实验里 Egress 对 80、8081 做七层处理，8080 按四层转发，
  代表“服务上没有被 Egress 覆盖的入口”。
- 8443：HTTPS（给了 --cert、--key 时）。
- 9443：HTTPS，并且要求客户端证书（另外给了 --client-ca 时）。身份取自证书的 CN。
- 8082：只在本机回环地址上监听，给前面的校验代理用（“一张证书加身份声明”的做法）。校验代理验过 Egress 的证书
  和身份声明之后，把认出的调用方放在请求头 x-verified-vm、x-verified-vm-ip 里交过来，这里原样报告成
  declared、declared_ip；x-verified-source 是校验代理看到的连接来源，报告成 forwarded_for。这个端口只信任校验代理，所以不对外监听。

凭证的三种形式：
- 请求头 x-egress-credential 里的令牌，认出的身份放在响应的 identity 里。
- 请求头 Authorization: Basic 里的账号和口令（静态凭证），认出的账号放在响应的 account 里。
- 客户端证书。私钥不在线路上传输，服务想回显也回显不出来。

凭证表（--tokens 指向的文件）每行“摘要 身份 [允许的来源]”：摘要是令牌或“账号:口令”的 SHA-256，
服务不保存凭证本身。第三列是一个地址或网段，写了就只接受从那里发来的这份凭证，
来源不符时返回 wrong-source；认不出的凭证返回 unknown。响应里不带凭证本身。

/reflect 把收到的请求头原样放进响应，TRACE 方法按 HTTP 的定义回显整个请求。
它们代表“服务端会把请求内容带回来”的情况（调试接口、错误页），实验用来演示令牌这种凭证的固有限制。
"""
import argparse
import base64
import hashlib
import ipaddress
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
VERIFIED_PORT = 8082


def recognize(secret, client):
    """从凭证表里找这份凭证。每次请求都重新读表，改了不用重启服务。"""
    digest = hashlib.sha256(secret.encode()).hexdigest()
    try:
        lines = open(ARGS.tokens).read().splitlines() if ARGS.tokens else []
    except OSError:
        lines = []
    for line in lines:
        parts = line.split()
        if len(parts) >= 2 and parts[0] == digest:
            if len(parts) >= 3 and ipaddress.ip_address(client) not in ipaddress.ip_network(parts[2], strict=False):
                return "wrong-source"
            return parts[1]
    return "unknown"


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
        client = self.client_address[0]
        token = self.headers.get(HEADER)
        identity = recognize(token, client) if token is not None else None
        account = None
        basic = self.headers.get("Authorization", "")
        if basic.lower().startswith("basic "):
            try:
                account = recognize(base64.b64decode(basic[6:]).decode(), client)
            except ValueError:
                account = "unknown"
        cert_cn = None
        if tls:
            for rdn in (self.connection.getpeercert() or {}).get("subject", ()):
                for key, value in rdn:
                    if key == "commonName":
                        cert_cn = value
        out = {
            "server": ARGS.name,
            "client": client,
            "tls": tls,
            "identity": identity,
            "account": account,
            "client_cert": cert_cn,
            "path": self.path,
        }
        if self.server.server_address[1] == VERIFIED_PORT:
            out["declared"] = self.headers.get("x-verified-vm")
            out["declared_ip"] = self.headers.get("x-verified-vm-ip")
            out["forwarded_for"] = self.headers.get("x-verified-source")   # 校验代理看到的连接来源
            out["saw_declaration"] = "yes" if self.headers.get("x-egress-identity") is not None else "no"
        if self.path.startswith("/reflect"):
            out["headers"] = dict(self.headers.items())
        self.reply(json.dumps(out).encode())

    def do_TRACE(self):
        lines = [self.requestline] + [f"{k}: {v}" for k, v in self.headers.items()]
        self.reply(("\r\n".join(lines) + "\r\n\r\n").encode(), "message/http")

    def log_message(self, *args):
        pass


def serve(port, ctx=None, bind="0.0.0.0"):
    srv = ThreadingHTTPServer((bind, port), Handler)
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
for port in (8080, 8081):
    threading.Thread(target=serve, args=(port,), daemon=True).start()
threading.Thread(target=serve, args=(VERIFIED_PORT, None, "127.0.0.1"), daemon=True).start()
serve(80)
