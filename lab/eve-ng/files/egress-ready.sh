#!/bin/bash
# Egress 的“就绪地址”，多台 Egress 之间做等价多路径时用。用法：egress-ready.sh <就绪地址>
#
# 接入路由器上的探测脚本靠 ping 判断一台 Egress 能不能用。ping 网卡地址只能说明机器开着：
# Egress 刚开机、Envoy 还没起来或者劫持规则还没加载时，分给它的连接都会失败。
# 所以让 Egress 自己判断：Envoy 的两个监听端口都在、透明劫持的规则已加载，才在面向虚拟机一侧的网卡上
# 配上就绪地址；连续三次不满足就撤掉。接入路由器只探测这个地址。做法和数据面 B 里网关的就绪地址相同。
. /etc/lab/ifaces.env
addr=$1 ok=0 bad=0 up=0
trap 'ip addr del "$addr/32" dev "$IF_ACC_NET" 2>/dev/null' EXIT
ip addr del "$addr/32" dev "$IF_ACC_NET" 2>/dev/null
ready() {
	[ -n "$(ss -Hltn 'sport = :15006')" ] && [ -n "$(ss -Hltn 'sport = :15007')" ] && nft list chain ip egress intercept >/dev/null 2>&1
}
while :; do
	if ready; then ok=$((ok + 1)); bad=0; else bad=$((bad + 1)); ok=0; fi
	if [ $up = 0 ] && [ $ok -ge 2 ]; then ip addr add "$addr/32" dev "$IF_ACC_NET" && up=1; logger -t lab-egress "已就绪，配上就绪地址 $addr"; fi
	if [ $up = 1 ] && [ $bad -ge 3 ]; then ip addr del "$addr/32" dev "$IF_ACC_NET"; up=0; logger -t lab-egress "不可用，撤掉就绪地址 $addr"; fi
	sleep 0.2
done
