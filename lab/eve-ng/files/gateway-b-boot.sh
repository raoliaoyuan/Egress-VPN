#!/bin/bash
# 数据面 B 在 VPN 网关上的开机部分，由 boot.sh 在最后调用：转发规则、回程路由、打开转发，最后才启动自己的隧道。
# 隧道放在最后：VPN 服务器靠“隧道里 ping 得通这台网关”判断它能不能用，隧道起来时转发必须已经就绪。
# @RETURN_ROUTES@ 由部署脚本替换成“地址块 回程地址”的列表。
. /etc/lab/ifaces.env
nft -f /etc/lab/gateway-b.nft
nft -f /etc/lab/gateway-b-sets.nft
sysctl -qw net.ipv4.ip_forward=1
while read -r block via; do
	[ -n "$block" ] && ip route replace "$block" via "$via" dev "$IF_SVC_NET"
done <<'ROUTES'
@RETURN_ROUTES@
ROUTES
systemctl start --no-block wg-quick@wgb.service
exit 0
