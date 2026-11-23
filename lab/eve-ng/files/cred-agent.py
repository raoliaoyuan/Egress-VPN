#!/usr/bin/env python3
"""Egress 本机的凭证代理：按“来源地址 × 服务”查这台虚拟机的凭证，交给 Envoy 写进请求头。

Envoy 的配置里只有按服务写的规则（目的地址、端口、Host 是这个服务，就来问凭证代理），没有凭证，
也没有任何一台虚拟机的地址。每台虚拟机各自的东西都在这里的一张表里，由控制面下发。
新增一台虚拟机是往表里加几行，Envoy 的配置不用动，也不用重启。

用法：
  cred-agent.py --table 文件 [--listen 127.0.0.1:9191] [--sign-key 私钥 --kid 名字 --issuer 签发者 --ttl 秒]
  cred-agent.py --jwks --sign-key 私钥 --kid 名字          输出这把签名密钥的公钥（JWKS），给校验的一侧用
  cred-agent.py --mint '<声明的 JSON>' --sign-key 私钥 --kid 名字   离线签一份声明，只用于验证“过期的、受众不对的会被拒绝”

表是文本文件，一行一条，“#”开头的是注释，第一行可以写“# version 版本号”：
  <来源地址> <服务> header <请求头名字> <请求头的值，到行尾>
      这台虚拟机在这个服务上用一份固定的凭证（令牌、Authorization: Basic …）。
  <来源地址> <服务> declare <内网 IP> <虚拟机标识>
      不用固定凭证：给它签一份短期的身份声明（JWT，ES256），说明这个请求是替哪台虚拟机发的。
      同一台虚拟机对同一个服务的声明在有效期内复用，不是每个请求签一次。
  <来源地址> * deny
      这台虚拟机被阻断：所有服务的请求都拒绝（Envoy 返回 403）。
表文件被替换（用重命名替换，保证读到的是完整的文件）之后一秒内自动加载。新表先完整解析，
解析成功才整张换上去；有错就保留旧表。

Envoy 的外部授权过滤器（HTTP 方式）每个请求来问一次：
  GET /lookup/…   请求头 x-lab-source 是来源地址，x-lab-service 是命中的规则对应的服务。
  应答 200 时，应答里的请求头由 Envoy 写进原请求（覆盖虚拟机自带的同名头）；查不到就应答 200、不带头，
  请求不带凭证转发出去；被阻断的应答 403。
GET /version 返回当前生效的表的版本和条数，控制面用它确认下发有没有生效。
"""
import argparse
import asyncio
import base64
import json
import os
import sys
import time

ap = argparse.ArgumentParser()
ap.add_argument("--table")
ap.add_argument("--listen", default="127.0.0.1:9191")
ap.add_argument("--sign-key")
ap.add_argument("--kid", default="egress")
ap.add_argument("--issuer", default="egress.lab")
ap.add_argument("--ttl", type=int, default=120)
ap.add_argument("--jwks", action="store_true")
ap.add_argument("--mint")
ARGS = ap.parse_args()
DECLARE_HEADER = "x-egress-identity"


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


KEY = None
if ARGS.sign_key:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    KEY = serialization.load_pem_private_key(open(ARGS.sign_key, "rb").read(), None)
    JWT_HEAD = b64(json.dumps({"alg": "ES256", "typ": "JWT", "kid": ARGS.kid}).encode())


def sign(claims):
    body = JWT_HEAD + b"." + b64(json.dumps(claims, separators=(",", ":")).encode())
    r, s = decode_dss_signature(KEY.sign(body, ec.ECDSA(hashes.SHA256())))
    return body + b"." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))


if ARGS.jwks:
    n = KEY.public_key().public_numbers()
    print(json.dumps({"keys": [{"kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": ARGS.kid,
                                "x": b64(n.x.to_bytes(32, "big")).decode(), "y": b64(n.y.to_bytes(32, "big")).decode()}]}))
    sys.exit()
if ARGS.mint:
    print(sign(json.loads(ARGS.mint)).decode())
    sys.exit()

TABLE, VERSION, LOADED_AT, MTIME = {}, "无", 0.0, None
DECLARED = {}   # (来源, 服务) -> (到期时间, 应答)
STATS = {"lookups": 0, "hit": 0, "miss": 0, "deny": 0, "signed": 0, "reloads": 0, "reload_errors": 0}
OK_EMPTY = b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"
DENY = b"HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n"
BAD = b"HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"


def load():
    """读表。返回 (表, 版本)；格式不对时抛异常，调用方保留旧表。"""
    table, version = {}, "未标注"
    with open(ARGS.table, encoding="utf-8") as f:
        for no, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                if line.startswith("# version "):
                    version = line[10:].strip()
                continue
            p = line.split(" ", 4)
            if len(p) == 3 and p[1] == "*" and p[2] == "deny":
                table[(p[0], "*")] = None
            elif len(p) == 5 and p[2] == "header":
                table[(p[0], p[1])] = b"HTTP/1.1 200 OK\r\n" + p[3].encode() + b": " + p[4].encode() + b"\r\ncontent-length: 0\r\n\r\n"
            elif len(p) == 5 and p[2] == "declare":
                if KEY is None:
                    raise ValueError(f"第 {no} 行要签发声明，但没有给签名密钥")
                table[(p[0], p[1])] = (p[3], p[4])
            else:
                raise ValueError(f"第 {no} 行格式不对")
    return table, version


def reload():
    global TABLE, VERSION, LOADED_AT, MTIME
    try:
        mtime = os.stat(ARGS.table).st_mtime_ns
    except OSError:
        return
    if mtime == MTIME:
        return
    MTIME = mtime
    t0 = time.time()
    try:
        table, version = load()
    except (OSError, ValueError, UnicodeError) as e:
        STATS["reload_errors"] += 1
        print(f"{time.time():.3f} 新表没有加载，保留版本 {VERSION}：{e}", flush=True)
        return
    TABLE, VERSION, LOADED_AT = table, version, time.time()
    DECLARED.clear()
    STATS["reloads"] += 1
    print(f"{time.time():.3f} 已加载版本 {version}，{len(table)} 条，用时 {time.time() - t0:.3f} 秒", flush=True)


def lookup(src, service):
    STATS["lookups"] += 1
    if (src, "*") in TABLE:
        STATS["deny"] += 1
        return DENY
    entry = TABLE.get((src, service))
    if entry is None:
        STATS["miss"] += 1
        return OK_EMPTY
    STATS["hit"] += 1
    if isinstance(entry, bytes):
        return entry
    now = time.time()
    cached = DECLARED.get((src, service))
    if cached and cached[0] > now:
        return cached[1]
    intra, name = entry
    token = sign({"iss": ARGS.issuer, "aud": service, "sub": name, "vm_ip": intra, "iat": int(now), "exp": int(now) + ARGS.ttl})
    STATS["signed"] += 1
    resp = b"HTTP/1.1 200 OK\r\n" + DECLARE_HEADER.encode() + b": " + token + b"\r\ncontent-length: 0\r\n\r\n"
    DECLARED[(src, service)] = (now + ARGS.ttl / 2, resp)   # 用到有效期的一半就换新的，留出传输和时钟偏差的余量
    return resp


async def serve(reader, writer):
    try:
        while True:
            try:
                head = await reader.readuntil(b"\r\n\r\n")
            except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError):
                break
            lines = head.split(b"\r\n")
            parts = lines[0].split(b" ")
            if len(parts) < 2:
                writer.write(BAD)
                break
            headers = {}
            for raw in lines[1:]:
                k, sep, v = raw.partition(b":")
                if sep:
                    headers[k.strip().lower()] = v.strip()
            length = int(headers.get(b"content-length", b"0") or 0)
            if length:
                await reader.readexactly(length)
            path = parts[1]
            if path.startswith(b"/lookup"):
                writer.write(lookup(headers.get(b"x-lab-source", b"").decode("latin1"), headers.get(b"x-lab-service", b"").decode("latin1")))
            elif path == b"/version":
                body = json.dumps({"version": VERSION, "entries": len(TABLE), "loaded_at": LOADED_AT, **STATS}).encode()
                writer.write(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
            else:
                writer.write(b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n")
            await writer.drain()
    except ConnectionError:
        pass
    finally:
        writer.close()


async def watch():
    while True:
        reload()
        await asyncio.sleep(0.5)


async def main():
    host, port = ARGS.listen.rsplit(":", 1)
    reload()
    server = await asyncio.start_server(serve, host, int(port), backlog=1024)
    asyncio.get_running_loop().create_task(watch())
    async with server:
        await server.serve_forever()


asyncio.run(main())
