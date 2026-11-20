#!/usr/bin/env python3
"""每次开机运行：按网卡 MAC 认出自己是哪个节点，设置主机名、各网卡地址和默认路由。

所有节点用同一个镜像。EVE 给节点 N 的第 i 块网卡分配的 MAC 是 00:50:00:00:<N 的十六进制>:<i>，
节点表在 /opt/lab/nodes.json。最后一块网卡总是管理网。
隧道、Envoy、nftables 等方案相关的配置不在这里，由操作机通过 SSH 下发。
"""
import glob
import json
import subprocess
import sys

CFG = json.load(open("/opt/lab/nodes.json"))


def sh(*args):
    subprocess.run(args, check=False)


nics = {}  # 网卡名 -> (节点编号, 网卡序号)
for path in glob.glob("/sys/class/net/*/address"):
    mac = open(path).read().strip()
    if mac.startswith("00:50:00:00:"):
        nics[path.split("/")[4]] = (int(mac[12:14], 16), int(mac[15:17], 16))
if not nics:
    sys.exit("lab-init: 没有找到 EVE 分配的网卡")

node_id = min(n for n, _ in nics.values())
node = next((n for n in CFG["nodes"] if n["id"] == node_id), None)
if node is None:
    sys.exit(f"lab-init: 节点表里没有编号 {node_id}")
dev_of = {i: dev for dev, (n, i) in nics.items() if n == node_id}

sh("hostname", node["name"])
open("/etc/hostname", "w").write(node["name"] + "\n")

env = []
for i, iface in enumerate(node["ifaces"]):
    dev = dev_of[i]
    sh("ip", "link", "set", "dev", dev, "up")
    sh("ip", "addr", "replace", iface["addr"], "dev", dev)
    env.append(f"IF_{iface['net'].replace('-', '_')}={dev}")
mgmt = dev_of[len(node["ifaces"])]
sh("ip", "link", "set", "dev", mgmt, "up")
sh("ip", "addr", "replace", node["mgmt"] + "/24", "dev", mgmt)
env.append(f"IF_MGMT={mgmt}")

if node.get("gw"):
    sh("ip", "route", "replace", "default", "via", node["gw"])
if node.get("forward"):
    sh("sysctl", "-qw", "net.ipv4.ip_forward=1")

subprocess.run(["mkdir", "-p", "/etc/lab"], check=False)
open("/etc/lab/ifaces.env", "w").write("\n".join(env) + "\n")

hosts = ["127.0.0.1 localhost", f"127.0.1.1 {node['name']}"]
hosts += [f"{ip} {name}" for name, ip in CFG["hosts"].items()]
open("/etc/hosts", "w").write("\n".join(hosts) + "\n")
print(f"lab-init: {node['name']} 就绪，网卡 {' '.join(env)}")
