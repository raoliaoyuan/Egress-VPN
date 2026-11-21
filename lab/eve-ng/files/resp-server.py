#!/usr/bin/env python3
"""一个要登录的非 HTTP 服务：Redis 协议（RESP）的最小实现，只用来做实验，不是真的 Redis。
用法：resp-server.py <服务名> --tokens 凭证表 [--cert 证书 --key 私钥 --client-ca 客户端CA]

它代表“凭证不在 HTTP 请求头里”的那一类服务（数据库、缓存、消息队列），用来看 Egress 对这类凭证能做什么。

端口：
- 6379：明文。连接后要先 AUTH <口令> 或 AUTH <账号> <口令>，否则任何命令都返回 NOAUTH。
- 6380：TLS，并且要求客户端证书（给了 --cert、--key、--client-ca 时）。身份取自证书的 CN，不用再登录。

凭证表与回显服务共用同一种格式：每行“摘要 身份 [允许的来源]”，摘要是口令或“账号:口令”的 SHA-256。
写了第三列时，只接受从那个地址或网段发来的这份凭证。

命令：AUTH、PING、ECHO、SET（只应答，不保存）、GET。GET whoami 返回一段 JSON：
服务看到的来源地址和它认出的调用方，供实验检查。
"""
import argparse
import hashlib
import ipaddress
import json
import socketserver
import ssl
import threading

ap = argparse.ArgumentParser()
ap.add_argument("name")
ap.add_argument("--tokens", required=True)
ap.add_argument("--cert")
ap.add_argument("--key")
ap.add_argument("--client-ca")
ARGS = ap.parse_args()


def recognize(secret, client):
    """从凭证表里找这份凭证：返回身份，或 wrong-source（来源不符）、None（认不出）。"""
    digest = hashlib.sha256(secret.encode()).hexdigest()
    try:
        lines = open(ARGS.tokens).read().splitlines()
    except OSError:
        lines = []
    for line in lines:
        parts = line.split()
        if len(parts) >= 2 and parts[0] == digest:
            if len(parts) >= 3 and ipaddress.ip_address(client) not in ipaddress.ip_network(parts[2], strict=False):
                return "wrong-source"
            return parts[1]
    return None


class Handler(socketserver.StreamRequestHandler):
    timeout = 30   # 空闲连接 30 秒后关闭

    def read_command(self):
        line = self.rfile.readline()
        if not line:
            return None
        if not line.startswith(b"*"):      # 不带长度的写法：一行里用空格分开
            return line.decode(errors="replace").split()
        args = []
        for _ in range(int(line[1:])):
            size = int(self.rfile.readline()[1:])
            args.append(self.rfile.read(size + 2)[:-2].decode(errors="replace"))
        return args

    def send(self, text):
        self.wfile.write(text.encode() + b"\r\n")

    def bulk(self, text):
        data = text.encode()
        self.wfile.write(b"$%d\r\n%s\r\n" % (len(data), data))

    def handle(self):
        client = self.client_address[0]
        tls = isinstance(self.connection, ssl.SSLSocket)
        cert_cn = None
        if tls:
            for rdn in (self.connection.getpeercert() or {}).get("subject", ()):
                for key, value in rdn:
                    if key == "commonName":
                        cert_cn = value
        identity = cert_cn   # 明文端口上要靠 AUTH 才有身份
        try:
            while True:
                args = self.read_command()
                if args is None:
                    return
                if not args:
                    continue
                cmd = args[0].upper()
                if cmd == "AUTH" and len(args) in (2, 3):
                    found = recognize(":".join(args[1:]), client)
                    if found == "wrong-source":
                        self.send("-WRONGSOURCE credential not accepted from this address")
                    elif found is None:
                        self.send("-WRONGPASS invalid username-password pair")
                    else:
                        identity = found
                        self.send("+OK")
                elif identity is None:
                    self.send("-NOAUTH Authentication required.")
                elif cmd == "PING":
                    self.send("+PONG")
                elif cmd == "ECHO" and len(args) == 2:
                    self.bulk(args[1])
                elif cmd == "SET":
                    self.send("+OK")
                elif cmd == "GET" and len(args) == 2:
                    if args[1] == "whoami":
                        self.bulk(json.dumps({"server": ARGS.name, "client": client, "tls": tls,
                                              "identity": identity, "client_cert": cert_cn}))
                    else:
                        self.send("$-1")
                else:
                    self.send("-ERR unknown command")
        except (OSError, ValueError):
            return


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def serve(port, ctx=None):
    srv = Server(("0.0.0.0", port), Handler)
    if ctx:
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()


if ARGS.cert:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(ARGS.cert, ARGS.key)
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_verify_locations(ARGS.client_ca)
    threading.Thread(target=serve, args=(6380, ctx), daemon=True).start()
serve(6379)
