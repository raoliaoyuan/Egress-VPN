#!/bin/bash
# VPN 网关每次开机执行：内核参数、方案的 nftables 规则、入口过滤和已登记的地址映射。
# 单元的隧道不在这里启动：同一个单元的网关共用一对密钥，由 keepalived 只在当上主用时启动。
. /etc/lab/ifaces.env
/etc/lab/tune.sh conntrack
sysctl -qw net.ipv4.ip_nonlocal_bind=1
sysctl -qw net.ipv4.ip_forward=0      # 数据面 A 的网关是连接的端点，不转发；数据面 B 的启动脚本再打开
nft delete table ip vpngw 2>/dev/null
nft -f /etc/lab/vpngw.nft
nft -f /etc/lab/gwfilter.nft
touch /etc/lab/vm2intra
/etc/lab/load-map.sh vpngw
[ -x /etc/lab/gateway-b-boot.sh ] && /etc/lab/gateway-b-boot.sh
exit 0
