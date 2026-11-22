#!/bin/bash
# 接入路由器每次开机执行：按源地址所在的块做策略路由，下一跳是这个块的接入地址。
# 它代表生产里已有的网络设备（子网路由表，或者宿主机虚拟交换机上的转发规则），自身不做高可用。
. /etc/lab/ifaces.env
/etc/lab/tune.sh
sysctl -qw net.ipv4.ip_forward=1
# 模拟的虚拟机网段（块 2、块 3）在 vm-farm 后面
ip route replace 10.2.0.0/16 via 10.1.253.2 dev "$IF_FARM_NET"
ip route replace 10.3.0.0/16 via 10.1.253.2 dev "$IF_FARM_NET"
# 块 → 路由表：块 1、块 2 用表 101，块 3 用表 102。每张表只有一条默认路由，指向这个块的接入地址。
# 接入地址由当前负责这个块的 Egress 持有（keepalived 漂移），Egress 故障时下一跳地址不变，只是换了一台机器应答。
# 目的地址在虚拟机一侧的（包括路由器自己在这些网段上的地址），先按主表走，不进块的路由表。
# 没有这一条，下面的反向路径检查会把虚拟机发给路由器自己的包（连 ARP 请求在内）都丢掉：
# 反查时“从 10.1.2.1 到 10.1.2.3”命中了块的规则，出口成了 Egress 那一侧，和包进来的网卡不一致。
for net in 10.1.2.0/24 10.2.0.0/16 10.3.0.0/16 10.1.253.0/24; do
	while ip rule del to "$net" lookup main 2>/dev/null; do :; done
	ip rule add to "$net" lookup main priority 900
done
while read -r block table; do
	while ip rule del from "$block" 2>/dev/null; do :; done
	ip rule add from "$block" lookup "$table" priority 1000
done <<'BLOCKS'
10.1.2.0/24 101
10.2.0.0/16 101
10.3.0.0/16 102
BLOCKS
ip route replace default via 10.1.254.101 dev "$IF_ACC_NET" table 101
ip route replace default via 10.1.254.102 dev "$IF_ACC_NET" table 102
# 反向路径检查：从虚拟机一侧进来的包，源地址必须属于这块网卡后面的网段，拦住跨网段冒用别人的地址。
# 同网段内的冒用它拦不住，那要在虚拟机接入的端口上校验。
sysctl -qw "net.ipv4.conf.$IF_VM_NET.rp_filter=1" "net.ipv4.conf.$IF_FARM_NET.rp_filter=1"
exit 0
