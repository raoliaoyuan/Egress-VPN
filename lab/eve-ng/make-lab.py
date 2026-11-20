#!/usr/bin/env python3
"""按 nodes.json 生成 EVE-NG 的实验文件（.unl），输出到标准输出。

节点和网络的编号从 21 起，避开同一台 EVE 上其他实验已经占用的小编号：
EVE 的网卡名、网桥名和控制台端口只由租户号和编号决定，不同实验用了相同编号就不能同时运行。
"""
import base64
import json
import os
import uuid
from xml.sax.saxutils import quoteattr as q

HERE = os.path.dirname(os.path.abspath(__file__))
cfg = json.load(open(os.path.join(HERE, "nodes.json")))
NS = uuid.UUID("6f0d3c1e-5b7a-4e2a-9c1f-2d4e5f6a7b80")
net_id = {n["name"]: n["id"] for n in cfg["networks"]}
lab = cfg["lab"]

out = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>']
out.append(
    f'<lab name={q(lab["name"])} id="{uuid.uuid5(NS, lab["name"])}" version="1" scripttimeout="300" lock="0" '
    f'author="Egress-VPN lab">'
)
out.append(f"  <description>{lab['description']}</description>")
out.append("  <topology>")
out.append("    <nodes>")
for n in cfg["nodes"]:
    nets = [i["net"] for i in n["ifaces"]] + ["MGMT"]
    out.append(
        f'      <node id="{n["id"]}" name={q(n["name"])} type="qemu" template="linux" image={q(lab["image"])} '
        f'console="telnet" cpu="1" cpulimit="1" ram="{n["ram"]}" ethernet="{len(nets)}" '
        f'uuid="{uuid.uuid5(NS, n["name"])}" firstmac="00:50:00:00:{n["id"]:02x}:00" '
        f'qemu_options="-machine type=pc,accel=kvm -vga std -usbdevice tablet -boot order=cd -cpu host" '
        f'qemu_version="2.4.0" qemu_arch="x86_64" qemu_nic="virtio-net-pci" delay="0" '
        f'icon="Server-2D-Linux-S.svg" config="0" left="{n["left"]}" top="{n["top"]}">'
    )
    for i, net in enumerate(nets):
        out.append(f'        <interface id="{i}" name="e{i}" type="ethernet" network_id="{net_id[net]}"/>')
    out.append("      </node>")
out.append("    </nodes>")
out.append("    <networks>")
for n in cfg["networks"]:
    icon = "cloud.png" if n["type"].startswith("pnet") else "lan.png"
    out.append(
        f'      <network id="{n["id"]}" type="{n["type"]}" name={q(n["name"])} left="{n["left"]}" top="{n["top"]}" '
        f'visibility="1" icon="{icon}"/>'
    )
out.append("    </networks>")
out.append("  </topology>")

# 每个节点都有一条线连到管理网，画面很乱。EVE 网页端的 visibility="0" 只对恰好接两个节点的网桥有效，
# 所以放一个文本对象，里面带一段样式，把连到 MGMT 的线和端口标签隐藏。样式只在打开本实验时生效，
# 在网页里删掉这段文字就恢复显示。
mgmt = next(n for n in cfg["networks"] if n["name"] == "MGMT")
for pad in range(16):
    note = (
        f'<div id="customText1" class="customShape customText context-menu" data-path="1" '
        f'style="display:inline;position:absolute;left:{max(mgmt["left"] - 15, 0)}px;top:{mgmt["top"] + 88}px; '
        f'cursor:move; ;z-index:1001;"{" " * pad}>'
        f'<p align="left" style="vertical-align:top;color:#808080;background-color:rgba(255, 255, 255, 0);'
        f'font-size:12px;font-weight: normal;">管理网的连线已隐藏：<br>每个节点的最后一块网卡接 MGMT。<br>'
        f'删除这段文字即可恢复显示。</p>'
        f'<style>svg.network{mgmt["id"]},.node_interface.network{mgmt["id"]}{{display:none!important}}</style></div>'
    )
    data = base64.b64encode(note.encode()).decode()
    # 网页端和服务端靠在数据里找 "div"、"style" 来判断它是不是已经解码，编码结果里碰巧出现就换一种对齐。
    if "div" not in data and "style" not in data.lower():
        break
else:
    raise SystemExit("文本对象的编码结果里总是出现 div 或 style")
out.append("  <objects>")
out.append("    <textobjects>")
out.append('      <textobject id="1" name="hide-mgmt-links" type="text">')
out.append(f"        <data>{data}</data>")
out.append("      </textobject>")
out.append("    </textobjects>")
out.append("  </objects>")
out.append("</lab>")
print("\n".join(out))
