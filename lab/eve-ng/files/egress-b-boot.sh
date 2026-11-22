#!/bin/bash
# 数据面 B 在 Egress 节点上的开机部分，由 boot.sh 在最后调用：内核规则、地址映射、把回程包交给本机的策略路由。
. /etc/lab/ifaces.env
nft -f /etc/lab/egress-b.nft
nft -f /etc/lab/egress-b-sets.nft
/etc/lab/load-map.sh egress_b
# 带标记 123 的回程包交给本机的 Envoy，而不是按目的地址（虚拟机的地址）转发走
while ip rule del iif "$IF_SVC_NET" fwmark 123 lookup 100 2>/dev/null; do :; done
ip rule add iif "$IF_SVC_NET" fwmark 123 lookup 100
ip route replace local 0.0.0.0/0 dev lo table 100
# 多条等价路由按五元组分流（默认只按地址），同一台虚拟机的不同连接才会分到不同的网关上
sysctl -qw net.ipv4.fib_multipath_hash_policy=1
exit 0
