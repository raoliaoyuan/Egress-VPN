#!/bin/bash
# VPN 网关每次开机执行：加载方案的 nftables 规则、入口过滤和已登记的地址映射。
# WireGuard 隧道不在这里启动：主备共用一对密钥，由 keepalived 只在当上主用时启动。
. /etc/lab/ifaces.env
sysctl -qw net.ipv4.ip_nonlocal_bind=1
nft delete table ip vpngw 2>/dev/null
nft -f /etc/lab/vpngw.nft
nft -f /etc/lab/gwfilter.nft
touch /etc/lab/vm2intra
while read -r real intra; do
	[ -n "$real" ] && nft add element ip vpngw vm2intra "{ $real : $intra }"
done < /etc/lab/vm2intra
exit 0
