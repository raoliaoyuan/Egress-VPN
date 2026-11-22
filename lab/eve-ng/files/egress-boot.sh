#!/bin/bash
# Egress 节点每次开机执行：内核参数、回程路由、透明劫持的规则；部署了数据面 B 的话再加载它的规则。
. /etc/lab/ifaces.env
/etc/lab/tune.sh conntrack
# 虚拟机的网段都在接入路由器后面。Egress 终结了虚拟机的连接，回包由它自己发出，经接入路由器回到虚拟机。
for net in 10.1.2.0/24 10.2.0.0/16 10.3.0.0/16 10.1.253.0/24; do
	ip route replace "$net" via 10.1.254.1 dev "$IF_ACC_NET"
done
nft -f /etc/lab/egress.nft
[ -x /etc/lab/egress-b-boot.sh ] && /etc/lab/egress-b-boot.sh
exit 0
