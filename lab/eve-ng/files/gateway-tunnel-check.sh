#!/bin/bash
# keepalived 的健康检查，也被 notify.sh 在启动隧道之前调用。两种用法，返回 0 是正常，非 0 是有问题：
#   gateway-tunnel-check.sh reach
#       能不能到至少一台 Egress（地址列在 /etc/lab/egress-peers 里，一行一个）。
#   gateway-tunnel-check.sh tunnel <隧道接口> <探测用的源地址> <隧道对面的探测目标>
#       本机承载着这个单元（隧道接口存在）时，经这条隧道能不能到 VPN 服务器后面的地址。
#       隧道接口不存在时返回 0：备用的一台不因为没有隧道被判成有问题。
#   gateway-tunnel-check.sh routed <内网网段>
#       本机有没有去这个网段的路由。多台 VPN 服务器的形态下隧道一直建着、路由从 BGP 学来，
#       一条都没有说明到每台服务器的会话都断了，这台网关承载不了任何单元。不管本机是不是主用都要查。
# keepalived 连续几次拿到非 0，就让这台网关退出相应的单元（实例进入故障状态，隧道随之停掉）。
#
# 只检查 Envoy 进程在不在是不够的：
#   - 进程在、隧道不通时，这个单元的流量全部进黑洞，而热备不会接管。tunnel 这一项就是查这个。
#     探测包的源地址是这个单元地址块里留出来的一个地址，只在隧道启动时配在隧道接口上（见 wg-unit.conf）。
#     要的是一来一回都成功，所以握手还在、单方向不通的情况也能发现。
#   - 一台 Egress 都到不了，说明这台网关在服务网段上被隔离了。它听不到别的网关的通告，会以为自己该当
#     所有单元的主用，把每个单元的隧道都启动起来；同一个单元的网关共用一对密钥，它一启动，
#     VPN 服务器上这个单元的对端就被它抢走，正在正常工作的那台网关的流量全部进黑洞。
#     所以 reach 这一项不管本机有没有承载单元都要查：够不着 Egress 的网关不参与选主，也不启动任何隧道。
# 文件 /etc/lab/tunnel-check-off 存在时两项都跳过，只用于对照（还原成“只看进程”的旧行为）。
[ -e /etc/lab/tunnel-check-off ] && exit 0
case "$1" in
reach)
	while read -r eg; do
		[ -n "$eg" ] && ping -c 1 -W 0.3 "$eg" >/dev/null 2>&1 && exit 0
	done < /etc/lab/egress-peers
	exit 1
	;;
tunnel)
	ip link show "$2" >/dev/null 2>&1 || exit 0
	ping -c 1 -W 0.5 -I "$3" "$4" >/dev/null 2>&1
	;;
routed)
	ip -4 route show "$2" | grep -q .
	;;
*) exit 2 ;;
esac
