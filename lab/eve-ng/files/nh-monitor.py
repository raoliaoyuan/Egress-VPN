#!/usr/bin/env python3
"""维护一条多路径路由：探测每个下一跳通不通，把不通的从路由里摘掉，恢复后放回去。

用法：nh-monitor.py <配置文件>
配置文件是 JSON：
  {"interval": 0.2, "fall": 3, "rise": 3,
   "routes": [{"prefix": "10.200.0.0/16",
               "nexthops": [{"name": "gw-1", "nexthop": "via 10.1.255.11 dev ens4", "probe": "10.1.255.11"}, …]}]}
prefix 后面可以带路由表，例如 "default table 110"。
每隔 interval 秒向每个下一跳的 probe 地址发一个 ICMP 请求；连续 fall 次没有应答判为不通，
连续 rise 次有应答判为恢复（启动后第一次有应答就算通）。状态变化时用 ip route replace 重写整条路由，
并在日志里记一行带时间的记录，故障注入时用来看多久发现的。

数据面 B 用它在两处做同一件事：
  - Egress 上，去内网的路由在各台网关之间分摊；
  - VPN 服务器上，回程去各地址块的路由在各台网关的隧道之间分摊。
“多台 Egress 之间做等价多路径”的实验（84-egress-ecmp.sh）也用它：接入路由器上，虚拟机的默认路由在各台 Egress 之间分摊。
它是让数据面 B 在实验里成立的最小做法。完整的做法是隧道里跑 BGP 加 BFD，由路由协议撤销不通的下一跳。
探测的地址由配置给：VPN 服务器探测的是网关在隧道里的地址；Egress 探测的是网关的“就绪地址”，
网关只在自己的隧道通、转发已打开时才配上它（见 gateway-b-health.sh），所以网关刚开机还没就绪、
或者网关活着而隧道断了，Egress 一侧都能发现。
"""
import json
import os
import select
import socket
import struct
import subprocess
import sys
import time

CFG = json.load(open(sys.argv[1]))
INTERVAL, FALL, RISE = CFG.get("interval", 0.2), CFG.get("fall", 3), CFG.get("rise", 3)
IDENT = os.getpid() & 0xFFFF


def log(msg):
    print(f"{time.time():.3f} {msg}", flush=True)


def checksum(data):
    s = sum(struct.unpack(f"!{len(data) // 2}H", data))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return ~s & 0xFFFF


def echo_request(seq):
    body = struct.pack("!HH", IDENT, seq) + b"nh-monitor"
    head = struct.pack("!BBH", 8, 0, 0)
    return struct.pack("!BBH", 8, 0, checksum(head + body)) + body


class Hop:
    def __init__(self, spec):
        self.name, self.nexthop, self.probe = spec["name"], spec["nexthop"], spec["probe"]
        self.up, self.ever, self.good, self.bad, self.answered = False, False, 0, 0, False


ROUTES = [(r["prefix"], [Hop(h) for h in r["nexthops"]]) for r in CFG["routes"]]
HOPS = {h.probe: h for _, hops in ROUTES for h in hops}


def apply(prefix, hops):
    alive = [h for h in hops if h.up]
    if not alive:
        subprocess.run(["ip", "route", "del"] + prefix.split(), stderr=subprocess.DEVNULL)
    elif len(alive) == 1:
        subprocess.run(["ip", "route", "replace"] + prefix.split() + alive[0].nexthop.split())
    else:
        cmd = ["ip", "route", "replace"] + prefix.split()
        for h in alive:
            cmd += ["nexthop"] + h.nexthop.split() + ["weight", "1"]
        subprocess.run(cmd)
    log(f"路由 {prefix}：{'、'.join(h.name for h in alive) or '没有可用的下一跳'}")


sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
sock.setblocking(False)
for prefix, hops in ROUTES:
    apply(prefix, hops)
seq = 0
while True:
    seq = (seq + 1) & 0xFFFF
    for h in HOPS.values():
        h.answered = False
        try:
            sock.sendto(echo_request(seq), (h.probe, 0))
        except OSError:
            pass
    deadline = time.monotonic() + INTERVAL
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            break
        if not select.select([sock], [], [], left)[0]:
            break
        try:
            pkt, (src, _) = sock.recvfrom(256)
        except OSError:
            continue
        ihl = (pkt[0] & 0x0F) * 4
        if len(pkt) >= ihl + 8:
            typ, _, _, ident, rseq = struct.unpack("!BBHHH", pkt[ihl:ihl + 8])
            if typ == 0 and ident == IDENT and rseq == seq and src in HOPS:
                HOPS[src].answered = True
    for prefix, hops in ROUTES:
        changed = False
        for h in hops:
            if h.answered:
                h.good, h.bad = h.good + 1, 0
                if not h.up and (h.good >= RISE or not h.ever):
                    h.up = h.ever = changed = True
                    log(f"{h.name} 通了")
            else:
                h.bad, h.good = h.bad + 1, 0
                if h.up and h.bad >= FALL:
                    h.up, changed = False, True
                    log(f"{h.name} 不通了（连续 {FALL} 次没有应答）")
        if changed:
            apply(prefix, hops)
