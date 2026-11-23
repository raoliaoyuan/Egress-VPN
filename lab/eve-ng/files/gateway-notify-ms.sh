#!/bin/bash
# keepalived 的状态通知（多台 VPN 服务器的形态）：当上某个单元的主用时开始通告这个单元的地址块，其余情况撤销。
# 隧道一直建着，这里不启停隧道。“通告”的做法是给每个块加一条黑洞路由：FRR 看到本机路由表里有这个块，
# 才把它通告给各台 VPN 服务器；同时把块放进 nftables 的集合 active_blocks，只有在里面的块才允许从隧道出去。
# 参数是 keepalived 给的：类型、实例名、状态。单元和地址块的对应关系在 /etc/lab/unit-blocks，每行“实例名 块 块…”。
blocks=$(awk -v u="$2" '$1 == u { $1 = ""; print }' /etc/lab/unit-blocks)
case "$3" in
MASTER)
	# 够不着任何一台 Egress 说明本机被隔离了，“当上主用”只是因为听不到别人，这时不通告。
	if [ -s /etc/lab/egress-peers ] && ! /etc/lab/tunnel-check.sh reach; then
		logger -t lab-gw "keepalived 实例 $2 状态 $3，但够不着任何一台 Egress，不通告地址块"
		exit 0
	fi
	for b in $blocks; do
		nft add element ip vpngw active_blocks "{ $b }" 2>/dev/null
		ip route replace blackhole "$b"
	done
	;;
*)
	for b in $blocks; do
		ip route del blackhole "$b" 2>/dev/null
		nft delete element ip vpngw active_blocks "{ $b }" 2>/dev/null
	done
	;;
esac
logger -t lab-gw "keepalived 实例 $2 状态 $3，本机通告的地址块：$(ip route show type blackhole | awk '{print $2}' | tr '\n' ' ')"
