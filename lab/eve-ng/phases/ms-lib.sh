# 多台 VPN 服务器同时工作的部署函数：`. "$(dirname "$0")/ms-lib.sh"`（在 common.sh、scale-lib.sh 之后）。
#
# 形态（数据面 A 的“目标做法”）：
#   - 每台网关自己一对密钥，到每台 VPN 服务器各一条隧道，一直建着。隧道里跑 BGP 加 BFD；
#   - 网关向服务器通告它此刻承载的单元的地址块；服务器再通告给内网核心路由器（rtr-core）；
#   - 内网核心向服务器通告内网网段，服务器再通告给网关。每个方向都有两条等价路由，按五元组分摊；
#   - 谁承载哪个单元仍然由 keepalived 决定（服务地址漂移），接管就是“开始通告这个单元的块”。
# 编号：服务器 S 是 1（vpn-server）和 2（vpn-server-2），网关 N 是 1 到 3。
#   隧道两端的互联地址：169.254.<S><N>.0（服务器）和 .1（网关），例如 gw-2 到 vpn-server-2 是 169.254.22.0/31；
#   服务器上对网关 N 的接口叫 wg-g<N>，端口 51840+N；网关上对服务器 S 的接口叫 wg-s<S>；
#   自治系统号：网关 6500<N>，服务器 6510<S>，内网核心 65200。
MS_SERVERS=(vpn-server vpn-server-2)
declare -A SRV_NUM=([vpn-server]=1 [vpn-server-2]=2)
declare -A SRV_WAN=([vpn-server]=203.0.113.1 [vpn-server-2]=203.0.113.2)
declare -A SRV_CORE=([vpn-server]=10.200.0.2 [vpn-server-2]=10.200.0.3)
declare -A SRV_KEY=([vpn-server]=server [vpn-server-2]=server2)
CORE_IP=10.200.0.1
CORE_AS=65200
INTRANET_NET=10.200.5.0/24
ALL_BLOCKS="$GATEWAY_BLOCK $BLOCK2_INTRA $BLOCK3_INTRA"
link_srv() { echo "169.254.$1$2.0"; }   # 服务器编号 网关编号
link_gw() { echo "169.254.$1$2.1"; }

frr_install() { # 节点 配置文件：装上配置，打开 bgpd 和 bfdd，重启 FRR
	put "$1" "$2" /etc/frr/frr.conf
	on "$1" "sed -i -e 's/^bgpd=.*/bgpd=yes/' -e 's/^bfdd=.*/bfdd=yes/' /etc/frr/daemons
chown frr:frr /etc/frr/frr.conf; chmod 640 /etc/frr/frr.conf
printf 'net.ipv4.fib_multipath_hash_policy = 1\n' > /etc/sysctl.d/90-lab-ms.conf; sysctl -q -p /etc/sysctl.d/90-lab-ms.conf
systemctl enable -q frr.service; systemctl restart frr.service"
}

deploy_ms_server() { # 服务器节点
	local srv=$1 s=${SRV_NUM[$1]} gw n
	for gw in "${ALL_GATEWAYS[@]}"; do
		n=${GW_NUM[$gw]}
		(umask 077; sed -e "s|<本服务器私钥>|$(wgkey "${SRV_KEY[$srv]}")|" -e "s|<本接口的端口，每台网关一个>|$((51840 + n))|" \
			-e "s|<本端互联地址>|$(link_srv "$s" "$n")|" -e "s|<该网关公钥>|$(wgpub "gwb-$n")|" \
			-e "s|<对端互联地址>|$(link_gw "$s" "$n")|" "$REPO/config/vpn-server/multi-server/wg-gateway.conf" > "$STATE/tmp")
		put_secret "$srv" "$STATE/tmp" "/etc/wireguard/wg-g$n.conf"
		on "$srv" "systemctl enable -q wg-quick@wg-g$n; systemctl restart wg-quick@wg-g$n"
	done
	sed -e "s|<本服务器名>|$srv|" -e "s|<本服务器AS>|6510$s|" -e "s|<本服务器路由器标识>|${SRV_CORE[$srv]}|" \
		-e "s|<网关1的互联地址>|$(link_gw "$s" 1)|g; s|<网关1AS>|65001|" \
		-e "s|<网关2的互联地址>|$(link_gw "$s" 2)|g; s|<网关2AS>|65002|" \
		-e "s|<网关3的互联地址>|$(link_gw "$s" 3)|g; s|<网关3AS>|65003|" \
		-e "s|<内网核心地址>|$CORE_IP|g; s|<内网核心AS>|$CORE_AS|" \
		"$REPO/config/vpn-server/multi-server/frr.conf" > "$STATE/tmp"
	# 内网网段从 BGP 学来：去掉开机脚本加的静态路由，并留下标记，开机时不再加
	on "$srv" "touch /etc/lab/ms-on; ip route del $INTRANET_NET 2>/dev/null; sysctl -qw net.ipv4.ip_forward=1; true"
	frr_install "$srv" "$STATE/tmp"
	rm -f "$STATE/tmp"
	echo "$srv：三个隧道接口，FRR 已启动"
}

deploy_ms_core() {
	sed -e "s|<本机名>|rtr-core|" -e "s|<本机AS>|$CORE_AS|" -e "s|<本机路由器标识>|$CORE_IP|" \
		-e "s|<服务器1在核心网段的地址>|${SRV_CORE[vpn-server]}|g; s|<服务器1AS>|65101|" \
		-e "s|<服务器2在核心网段的地址>|${SRV_CORE[vpn-server-2]}|g; s|<服务器2AS>|65102|" \
		"$REPO/config/intranet-core/frr.conf" > "$STATE/tmp"
	on rtr-core "touch /etc/lab/ms-on; for b in $ALL_BLOCKS; do ip route del \$b 2>/dev/null; done; true"
	frr_install rtr-core "$STATE/tmp"
	rm -f "$STATE/tmp"
	echo "rtr-core：FRR 已启动"
}

# deploy_ms_gateway <网关> <单元 1 的优先级> <单元 2 的优先级> <VRRP 通告间隔>
# 在规模化形态的基础上改：停掉按单元的隧道，换成到每台服务器的隧道；规则、通知脚本、keepalived 换成这个形态的。
# keepalived 只装好配置，不在这里启动（启动顺序决定谁当主用，由调用方安排）。
deploy_ms_gateway() {
	local gw=$1 n=${GW_NUM[$1]} srv s
	on "$gw" "systemctl stop keepalived.service 2>/dev/null
systemctl disable -q --now wg-quick@wg0 wg-quick@wg1 2>/dev/null; rm -f /etc/wireguard/wg0.conf /etc/wireguard/wg1.conf
for t in 201 202; do ip route flush table \$t 2>/dev/null; done; true"
	for srv in "${MS_SERVERS[@]}"; do
		s=${SRV_NUM[$srv]}
		(umask 077; sed -e "s|<本网关私钥>|$(wgkey "gwb-$n")|" -e "s|<本端互联地址>|$(link_gw "$s" "$n")|" \
			-e "s|<该服务器公钥>|$(wgpub "${SRV_KEY[$srv]}")|" -e "s|<该服务器地址>|${SRV_WAN[$srv]}|" \
			-e "s|<本网关在该服务器上的端口>|$((51840 + n))|" -e "s|<对端互联地址>|$(link_srv "$s" "$n")|" \
			"$REPO/config/vpn-gateway/multi-server/wg-server.conf" > "$STATE/tmp")
		put_secret "$gw" "$STATE/tmp" "/etc/wireguard/wg-s$s.conf"
	done
	sed -e "s|<本网关名>|$gw|" -e "s|<本网关AS>|6500$n|" -e "s|<本网关路由器标识>|${SVC_IP[$gw]}|" \
		-e "s|<服务器1的互联地址>|$(link_srv 1 "$n")|g; s|<服务器1AS>|65101|" \
		-e "s|<服务器2的互联地址>|$(link_srv 2 "$n")|g; s|<服务器2AS>|65102|" \
		"$REPO/config/vpn-gateway/multi-server/frr.conf" > "$STATE/tmp"
	put "$gw" "$REPO/config/vpn-gateway/multi-server/vpngw.nft" /etc/lab/vpngw.nft
	put "$gw" "$FILES/gateway-notify-ms.sh" /etc/lab/notify.sh
	put "$gw" "$FILES/gateway-tunnel-check.sh" /etc/lab/tunnel-check.sh
	put "$gw" "$FILES/keepalived-units-ms.conf" /etc/keepalived/keepalived.conf.in
	put "$gw" "$FILES/keepalived-stop-ms.conf" /etc/systemd/system/keepalived.service.d/stop-tunnel.conf
	printf 'U1 %s %s\nU2 %s\n' "$GATEWAY_BLOCK" "$BLOCK2_INTRA" "$BLOCK3_INTRA" > "$STATE/tmp2"
	put "$gw" "$STATE/tmp2" /etc/lab/unit-blocks
	rm -f "$STATE/tmp2"
	on "$gw" ". /etc/lab/ifaces.env
chmod 755 /etc/lab/notify.sh /etc/lab/tunnel-check.sh
rm -f /etc/lab/tunnel-check-off
printf '10.1.255.20\\n10.1.255.21\\n' > /etc/lab/egress-peers
sed -e \"s/@SVCIF@/\$IF_SVC_NET/g\" -e 's/@PRIO1@/$2/; s/@PRIO2@/$3/; s/@ADVERT@/$4/g' -e 's|@INTRANET@|$INTRANET_NET|g' \\
	/etc/keepalived/keepalived.conf.in > /etc/keepalived/keepalived.conf
echo 0 > /etc/lab/hold-U1; echo 0 > /etc/lab/hold-U2
for b in $ALL_BLOCKS; do ip route del blackhole \$b 2>/dev/null; done
systemctl daemon-reload
systemctl restart lab-boot.service
for s in 1 2; do systemctl enable -q wg-quick@wg-s\$s; systemctl restart wg-quick@wg-s\$s; done"
	frr_install "$gw" "$STATE/tmp"
	rm -f "$STATE/tmp"
	echo "$gw：两条隧道，FRR 已启动，映射表 $(on "$gw" "wc -l < /etc/lab/vm2intra") 条"
}

# reset_ms：撤掉多台服务器形态的东西（回到规模化形态之前先调用；30-deploy-solution.sh 经 reset_to_base 调用）。
reset_ms() {
	local n
	rm -f "$STATE/ms-on"
	for n in "${ALL_GATEWAYS[@]}"; do
		on "$n" "systemctl stop keepalived.service 2>/dev/null
systemctl disable -q --now frr.service 2>/dev/null
for s in 1 2; do systemctl disable -q --now wg-quick@wg-s\$s 2>/dev/null; rm -f /etc/wireguard/wg-s\$s.conf; done
for b in $ALL_BLOCKS; do ip route del blackhole \$b 2>/dev/null; done
rm -f /etc/lab/unit-blocks /etc/sysctl.d/90-lab-ms.conf; true" 2>/dev/null || true
	done
	for n in "${MS_SERVERS[@]}"; do
		# wg0 也停掉：这个形态下它的地址是单个地址，别的形态下是整块。接口留着的话，之后只同步对端、
		# 不会改地址和路由，旧方式的虚拟机和网关的回程就没有路由了。停掉之后由 apply_server_conf 按新配置重新启动。
		on "$n" "systemctl disable -q --now frr.service 2>/dev/null
systemctl stop wg-quick@wg0 2>/dev/null
for g in 1 2 3; do systemctl disable -q --now wg-quick@wg-g\$g 2>/dev/null; rm -f /etc/wireguard/wg-g\$g.conf; done
nft delete table ip labfw 2>/dev/null
rm -f /etc/lab/ms-on /etc/sysctl.d/90-lab-ms.conf; /etc/lab/boot.sh; true" 2>/dev/null || true
	done
	on rtr-core "systemctl disable -q --now frr.service 2>/dev/null; nft delete table ip labfw 2>/dev/null
rm -f /etc/lab/ms-on /etc/sysctl.d/90-lab-ms.conf; /etc/lab/boot.sh; true" 2>/dev/null || true
}

# ---------- 查看状态 ----------
bgp_up() { # 节点：建立起来的 BGP 会话数
	on "$1" "vtysh -c 'show bgp ipv4 unicast summary json' 2>/dev/null" | jq '[(.ipv4Unicast.peers // .peers // {}) | .[] | select(.state == "Established")] | length' 2>/dev/null || echo 0
}
bfd_up() { on "$1" "vtysh -c 'show bfd peers json' 2>/dev/null" | jq '[.[] | select(.status == "up")] | length' 2>/dev/null || echo 0; }
nexthops() { # 节点 前缀：这个前缀在内核路由表里有几个下一跳
	on "$1" "ip -4 route show $2 | grep -oE '(via|nexthop via) [0-9.]+' | wc -l"
}
advertised() { # 网关：它此刻通告着的块（按黑洞路由看）
	on "$1" "ip route show type blackhole | awk '{print \$2}' | sort | tr '\n' ' '" | sed 's/ $//'
}
# wait_bgp：等所有会话建立、各处的路由到齐（最长两分钟）。
wait_bgp() {
	local i
	for i in $(seq 1 60); do
		if [ "$(bgp_up rtr-core)" = 2 ] && [ "$(bgp_up vpn-server)" = 4 ] && [ "$(bgp_up vpn-server-2)" = 4 ] \
			&& [ "$(nexthops rtr-core "$BLOCK3_INTRA")" = 2 ] && [ "$(nexthops rtr-core "$BLOCK2_INTRA")" = 2 ]; then
			return 0
		fi
		sleep 2
	done
	return 1
}
