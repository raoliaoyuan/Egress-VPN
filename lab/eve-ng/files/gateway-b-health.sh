#!/bin/bash
# 数据面 B：网关的“就绪地址”。用法：gateway-b-health.sh <VPN 服务器在本隧道上的地址> <就绪地址>
#
# Egress 上的探测脚本靠 ping 判断一台网关能不能用。如果它 ping 的是网关自己的网卡地址，
# 网关刚开机、隧道还没握手或者转发还没打开时就会被当成可用，这段时间分给它的连接都被丢掉
# （实验里测到过：网关重新加入时约 1 秒的新连接失败）。网关的隧道断了而机器还活着时也一样发现不了。
# 所以让网关自己判断：转发已打开、并且经自己的隧道能 ping 通 VPN 服务器时，才在面向 Egress 的网卡上
# 配上就绪地址；连续三次不通就撤掉。Egress 只探测这个地址。
. /etc/lab/ifaces.env
peer=$1 addr=$2 ok=0 bad=0 up=0
trap 'ip addr del "$addr/32" dev "$IF_SVC_NET" 2>/dev/null' EXIT
ip addr del "$addr/32" dev "$IF_SVC_NET" 2>/dev/null
while :; do
	if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] && ping -c1 -W0.3 -q "$peer" >/dev/null 2>&1; then
		ok=$((ok + 1)); bad=0
	else
		bad=$((bad + 1)); ok=0
	fi
	if [ $up = 0 ] && [ $ok -ge 2 ]; then ip addr add "$addr/32" dev "$IF_SVC_NET" && up=1; logger -t lab-gwb "隧道已通，配上就绪地址 $addr"; fi
	if [ $up = 1 ] && [ $bad -ge 3 ]; then ip addr del "$addr/32" dev "$IF_SVC_NET"; up=0; logger -t lab-gwb "隧道不通，撤掉就绪地址 $addr"; fi
	sleep 0.2
done
