#!/usr/bin/env bash
# 阶段 8.3：同网段内冒用别人的源地址（先执行 80-scale-a.sh）。
# 凭证和内网 IP 都按源地址选，所以一台虚拟机冒用同网段里另一台的地址，就同时拿到对方的两个身份。
# 跨网段的冒用由接入路由器的反向路径检查拦住（81-scale-a-verify.sh 的 C），同网段内的它拦不住，
# 要在虚拟机接入网络的那个端口上校验。这里在 vm-farm 上搭一个最小的“宿主机”来测：
#   - 一个网桥 br-vm 当虚拟交换机，网关地址 10.2.190.1；
#   - 两个网络命名空间 vmx（10.2.190.11）、vmy（10.2.190.12）当两台虚拟机，各经一对虚拟网卡接到网桥的一个端口上；
#   - 端口校验是一张 bridge 族的 nftables 表：每个端口只放行它自己的 MAC 和 IP，ARP 里声称的 IP 也要是它自己的。
# 这两个地址在块 2 里、已经登记过（内网 IP 是 100.66.190.11 和 .12）。测完全部拆掉，vm-farm 恢复原样。
#   1 两台各自正常访问内网，来源是各自的内网 IP；
#   2 开着端口校验，vmy 冒用 vmx 的地址：只冒用 IP、连 MAC 一起冒用，都发不出去；
#   3 对照：关掉端口校验，vmy 冒用成功，内网服务把它当成 vmx；
#   4 恢复端口校验后冒用再次失败，vmx 自己仍然正常。
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/bench-lib.sh"
. "$(dirname "$0")/scale-lib.sh"
scale_on || die "还不是规模化形态，先执行 80-scale-a.sh"
NET=10.2.190; X=$NET.11; Y=$NET.12; GW=$NET.1
INTRA_X=100.66.190.11; INTRA_Y=100.66.190.12
BLOCK2_EGRESS=$(access_holder "$ACCESS_VIP")

teardown() {
	on vm-farm "nft delete table bridge vmguard 2>/dev/null
ip netns del vmx 2>/dev/null; ip netns del vmy 2>/dev/null; ip link del br-vm 2>/dev/null
sysctl -qw net.ipv4.ip_forward=0; true" || true
}
trap teardown EXIT

say "在 vm-farm 上搭两台同网段的虚拟机"
put vm-farm "$FILES/arp-claim.py" /usr/local/bin/arp-claim.py
teardown
on vm-farm "set -e
ip link add br-vm type bridge
ip link set br-vm up
ip addr add $GW/24 dev br-vm
for v in x:11 y:12; do
	n=\${v%:*}; a=\${v#*:}
	ip netns add vm\$n
	ip link add vp-\$n type veth peer name eth0 netns vm\$n
	ip link set vp-\$n master br-vm up
	ip -n vm\$n link set lo up
	ip -n vm\$n link set eth0 up
	ip -n vm\$n addr add $NET.\$a/24 dev eth0
	ip -n vm\$n route add default via $GW
done
# vm-farm 平时把 10.2.0.0/16 整段当成本机地址（给压测工具绑定源地址用）。这一小段要真的送到网桥上，
# 所以在同一张表（local）里加一条更具体的路由压过它。
ip route add $NET.0/24 dev br-vm table local
sysctl -qw net.ipv4.ip_forward=1"
MAC_X=$(on vm-farm "ip -n vmx -br link show eth0 | awk '{print \$3}'")
MAC_Y=$(on vm-farm "ip -n vmy -br link show eth0 | awk '{print \$3}'")
guard_on() {
	on vm-farm "nft delete table bridge vmguard 2>/dev/null
nft -f - <<NFT
table bridge vmguard {
	chain pre {
		type filter hook prerouting priority -300; policy accept;
		iifname \"vp-x\" ether saddr != $MAC_X drop
		iifname \"vp-x\" ether type ip ip saddr != $X drop
		iifname \"vp-x\" ether type arp arp saddr ip != $X drop
		iifname \"vp-y\" ether saddr != $MAC_Y drop
		iifname \"vp-y\" ether type ip ip saddr != $Y drop
		iifname \"vp-y\" ether type arp arp saddr ip != $Y drop
	}
}
NFT"
}
guard_off() { on vm-farm "nft delete table bridge vmguard"; }
ns_get() { # 命名空间 源地址：从这台“虚拟机”访问内网服务，输出服务看到的来源
	local out
	out=$(on vm-farm "ip netns exec $1 curl -s -m 4 --interface $2 http://$INTRANET_IP:$FAST_HTTP_L4/ || echo '{}'" 2>/dev/null) || true
	echo "${out:-{\}}" | field client
}
# impersonate [mac]：vmy 把 vmx 的地址配到自己的网卡上，不断向网关声称“这个 IP 是我的”，然后用它访问内网服务。
# 带 mac 时连网卡的 MAC 也改成 vmx 的。输出内网服务看到的来源；发不出去或收不到回包时是“无”。
impersonate() {
	local out
	out=$(on vm-farm "[ '${1:-}' = mac ] && { ip -n vmy link set eth0 down; ip -n vmy link set eth0 address $MAC_X; ip -n vmy link set eth0 up; ip -n vmy route replace default via $GW; }
ip -n vmy addr add $X/32 dev eth0
ip netns exec vmy python3 /usr/local/bin/arp-claim.py eth0 $X $GW 5 >/dev/null 2>&1 &
sleep 1
ip netns exec vmy curl -s -m 3 --interface $X http://$INTRANET_IP:$FAST_HTTP_L4/ || echo '{}'
wait
ip -n vmy addr del $X/32 dev eth0
[ '${1:-}' = mac ] && { ip -n vmy link set eth0 down; ip -n vmy link set eth0 address $MAC_Y; ip -n vmy link set eth0 up; ip -n vmy route replace default via $GW; }
true" 2>/dev/null) || true
	echo "${out:-{\}}" | field client
}
# spoofed_at_egress：vmy 用 vmx 的地址向一个没人用的端口（4242）发连接，数一数有几个包到了 Egress。
spoofed_at_egress() {
	on "$BLOCK2_EGRESS" '. /etc/lab/ifaces.env; rm -f /tmp/spoof2.pcap; timeout 7 tcpdump -ni $IF_ACC_NET -w /tmp/spoof2.pcap "src host '"$X"' and tcp dst port 4242" >/dev/null 2>&1 &'
	on vm-farm "sleep 1; ip -n vmy addr add $X/32 dev eth0
ip netns exec vmy python3 -c \"
import socket
for _ in range(3):
    s = socket.socket(); s.bind(('$X', 0)); s.settimeout(0.5)
    try: s.connect(('$INTRANET_IP', 4242))
    except OSError: pass
    s.close()
\"; ip -n vmy addr del $X/32 dev eth0; sleep 7" >/dev/null 2>&1 || true
	on "$BLOCK2_EGRESS" "tcpdump -nr /tmp/spoof2.pcap 2>/dev/null | wc -l"
}
vmx_fresh() { on vm-farm "ip -n vmx neigh flush all; ip netns exec vmx ping -c 2 -i 0.3 -W 1 $GW >/dev/null 2>&1; true"; }

say "1 正常访问"
guard_on
check "1 vmx 访问内网，来源是它的内网 IP" "$INTRA_X" "$(ns_get vmx $X)"
check "1 vmy 访问内网，来源是它的内网 IP" "$INTRA_Y" "$(ns_get vmy $Y)"

say "2 开着端口校验，vmy 冒用 vmx 的地址"
check "2 只冒用 IP：内网服务看到的来源" 无 "$(impersonate)"
check "2 连 MAC 一起冒用：内网服务看到的来源" 无 "$(impersonate mac)"
check "2 冒用的包到达 Egress 的个数" 0 "$(spoofed_at_egress)"
check "2 vmy 用自己的地址仍然正常" "$INTRA_Y" "$(ns_get vmy $Y)"

say "3 对照：关掉端口校验"
guard_off
ctrl "3 vmy 冒用 vmx 的地址成功，内网服务把它当成 vmx" "$INTRA_X" "$(impersonate)"
n=$(spoofed_at_egress)
if [ "$n" -gt 0 ]; then echo "对照成立：3 冒用的包到达了 Egress（$n 个）"; else echo "失败：3 对照组没有抓到包"; FAILS=$((FAILS + 1)); fi

say "4 恢复端口校验"
guard_on
check "4 再次冒用：内网服务看到的来源" 无 "$(impersonate)"
vmx_fresh
check "4 vmx 自己仍然正常" "$INTRA_X" "$(ns_get vmx $X)"

say "拆掉"
teardown
trap - EXIT
sleep 1
check "vm-farm 恢复原样：压测工具仍能用这个地址当源" "$INTRA_X" "$(farm_get $X "http://$INTRANET_IP:$FAST_HTTP_L4/" | field client)"
finish
