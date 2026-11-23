#!/bin/bash
# keepalived 的状态通知：当上某个单元的主用时启动这个单元的隧道，其余情况停掉。
# 同一个单元的网关共用一对 WireGuard 密钥，同一时刻只能有一台持有这个单元的隧道。
# 参数是 keepalived 给的：类型、实例名、状态。实例 GW（只有一个单元时）和 U1 对应 wg0，U2 对应 wg1。
case "$2" in
U2) wg=wg1 ;;
*) wg=wg0 ;;
esac
case "$3" in
MASTER)
	# 启动隧道之前再确认一次够得着 Egress。够不着说明本机被隔离了：这时“当上主用”只是因为听不到别人，
	# 启动隧道会把正常工作的那台网关的对端地址抢走。健康检查随后会让这个实例进入故障状态。
	if [ -x /etc/lab/tunnel-check.sh ] && [ -s /etc/lab/egress-peers ] && ! /etc/lab/tunnel-check.sh reach; then
		logger -t lab-gw "keepalived 实例 $2 状态 $3，但够不着任何一台 Egress，不启动隧道 $wg"
		exit 0
	fi
	systemctl start "wg-quick@$wg"
	;;
*) systemctl stop "wg-quick@$wg" ;;
esac
logger -t lab-gw "keepalived 实例 $2 状态 $3，隧道 $wg $(ip link show "$wg" >/dev/null 2>&1 && echo 已启动 || echo 已停止)"
