#!/bin/bash
# 内网核心路由器每次开机执行。它代表企业内网里已有的路由设备（自身不做高可用）：
# 一边是 VPN 服务器和企业的互联网出口（CORE-NET），一边是内网服务（INTRANET）。
# 虚拟机的内网地址块都在 VPN 服务器后面。只有一台服务器时用静态路由指过去；
# 多台服务器的形态下每个块从各台服务器的 BGP 通告学来，有几台就有几条等价路由（这里不加静态的）。
. /etc/lab/ifaces.env
/etc/lab/tune.sh
sysctl -qw net.ipv4.ip_forward=1
if [ ! -e /etc/lab/ms-on ]; then
	for block in 100.64.0.0/22 100.66.0.0/16 100.67.0.0/16; do
		ip route replace "$block" via 10.200.0.2 dev "$IF_CORE_NET"
	done
fi
exit 0
