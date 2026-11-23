#!/usr/bin/env bash
# 阶段 8.8：验证多台 VPN 服务器同时工作（先执行 87-multi-server.sh）。
#   A 分摊和身份：两个块的每个身份都发请求，来源必须正确；两台服务器确实都在转发；
#   S 一台 VPN 服务器断电：已有的长连接断不断、新连接多久恢复；回来之后重新加入；
#   G 一台网关断电（gw-2，单元 2 的主用）：共享热备靠“开始通告地址块”接管，不用启动隧道；然后正常切回；
#   L 一条隧道不通、两端都活着（gw-1 到 vpn-server 的那条）：只撤掉这一条邻接；
#   F 服务器和内网之间的有状态防火墙：
#       共用一套（放在内网核心上）：去程和回程走不同的服务器也认得，一台服务器断电连接不断；
#       各自独立（对照，放在每台服务器上）：回程从另一台回来被当成无效包丢掉；
#       退路：让一台服务器做主用、另一台做备用，去程和回程走同一台，各自独立的防火墙下也通；
#   M 和迁移并存：把 vm-c 退回旧方式（自带隧道，vpn-server 的 wg0 上一个 /32 对端），和新方式并存，再迁移回来；
#   P 主备之间互相听不到（gw-2 和 gw-3）：这个形态下两台都通告同一个块，只测后果。
# 通过的标准：身份不符始终是 0；服务器断电、单条隧道不通时已有的长连接一条不断，新连接的中断不超过 MAX_SRV 秒（默认 3）；
# 网关断电的中断不超过 MAX_SWITCH 秒（默认 8）。
# 用法：88-multi-server-verify.sh [A S G L F M P 里的若干个，默认全部]
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/bench-lib.sh"
. "$(dirname "$0")/scale-lib.sh"
. "$(dirname "$0")/ms-lib.sh"
ms_on || die "还不是多台 VPN 服务器的形态，先执行 87-multi-server.sh"
SECTIONS=${*:-A S G L F M P}
MAX_SRV=${MAX_SRV:-3}
MAX_SWITCH=${MAX_SWITCH:-8}
want() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }
PATH_M="vm-farm egress-1 egress-2 gw-1 gw-2 gw-3 vpn-server vpn-server-2 rtr-core intranet-svc"
fwd_bytes() { on "$1" "wg show all transfer | awk '\$1 ~ /^wg-g/ { s += \$3 + \$4 } END { print s + 0 }'"; }
steady() { # 等两个块都连续 8 次访问成功
	local ok=0 i
	for i in $(seq 1 120); do
		if [ "$(TIMEOUT=2 farm_get 10.2.0.9 "http://$INTRANET_IP:$FAST_HTTP_L4/" | field client)" = 100.66.0.9 ] \
			&& [ "$(TIMEOUT=2 farm_get 10.3.0.9 "http://$INTRANET_IP:$FAST_HTTP_L4/" | field client)" = 100.67.0.9 ]; then ok=$((ok + 1)); else ok=0; fi
		[ $ok -ge 8 ] && return 0
		sleep 0.5
	done
	return 1
}
before() { units_home || die "单元没有回到第一顺位"; wait_bgp || die "BGP 会话或路由没有到齐"; steady || die "开始前两个块没有稳定下来"; sleep 2; }
both_ok() { # 这一项的名字 中断上限：两个块都没有串、都恢复了、长连接一条不断
	local b fb fs
	for b in 2 3; do
		eval "fb=\$F_B$b; fs=\$F_S$b"
		check "$1 块 $b：身份不符 $(fj "$fb" .err_mismatch) 个，新连接中断 $(fj "$fb" '.outage.outage_s // "没有恢复"') 秒（不超过 $2 秒），60 条长连接断了 $(fj "$fs" .broken) 条" "0 是 0" \
			"$(fj "$fb" .err_mismatch) $(within "$(fj "$fb" .outage.outage_s)" "$2") $(fj "$fs" .broken)"
		echo "  块 $b：失败的请求 $(fj "$fb" .errors) 个；没断的长连接最长卡了 $(fj "$fs" .max_gap) 秒"
	done
}

if want A; then
	say "A 分摊和身份"
	before
	b1=$(fwd_bytes vpn-server); b2=$(fwd_bytes vpn-server-2)
	for spec in "2 10.2.0.1 100.66.0.1" "3 10.3.0.1 100.67.0.1"; do
		set -- $spec
		run_load "ms/身份/块$1/四层" vm-farm 40 "$PATH_M" --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base "$2" --src-count "$FARM_PER_BLOCK" \
			--expect-base "$3" --conns 128 --threads 3
		check "A 块 $1：失败数和身份不符数" "0 0" "$(fj "$LAST_LOAD" '"\(.errors) \(.err_mismatch)"')"
		echo "  覆盖的身份：$(fj "$LAST_LOAD" "if .opened >= $FARM_PER_BLOCK then \"全部 $FARM_PER_BLOCK 个\" else \"\(.opened) 个\" end")"
	done
	d1=$(( $(fwd_bytes vpn-server) - b1 )); d2=$(( $(fwd_bytes vpn-server-2) - b2 ))
	echo "  这段时间两台服务器经隧道收发的字节数：vpn-server $d1，vpn-server-2 $d2"
	check "A 两台服务器都在转发（各自至少占三成）" "是 是" "$(within $((d1 + d2)) $((d1 * 10 / 3))) $(within $((d1 + d2)) $((d2 * 10 / 3)))"
	run_iperf "ms/吞吐/块3/下行" vm-farm 20 "$PATH_M" -B 10.3.0.7 -R -P 4
	run_iperf "ms/吞吐/块3/上行" vm-farm 20 "$PATH_M" -B 10.3.0.7 -P 4
fi

if want S; then
	for victim in vpn-server-2 vpn-server; do
		say "S 一台 VPN 服务器断电：$victim"
		before
		fault_power "ms/服务器断电/$victim" "$victim"
		both_ok "S $victim 断电" "$MAX_SRV"
		check "S 内网核心上每个块只剩 1 个下一跳" "1 1" "$(nexthops rtr-core "$BLOCK2_INTRA") $(nexthops rtr-core "$BLOCK3_INTRA")"
		check "S 单元没有换网关（服务器故障不触发网关切换）" "gw-1 gw-2" "$(unit_holders "$GATEWAY_VIP") $(unit_holders "$GATEWAY_VIP2")"
		on rtr-core "journalctl -u frr --since -90s --no-pager -o cat 2>/dev/null | grep -iE 'bfd|Down|ADJCHANGE' | tail -3 | sed 's/^/  内网核心的日志：/'" || true

		say "S（续）$victim 回来，重新加入"
		for b in 2 3; do
			load_bg vm-farm "b$b" --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base "10.$b.0.1" --src-count "$FARM_PER_BLOCK" --expect-base "100.6$((b + 4)).0.1" \
				--conns 300 --rate 300 --timeout 1000 --duration 90
			stream_bg vm-farm "s$b" --target "$INTRANET_IP:$ECHO_PORT" --src-base "10.$b.1.1" --count 60 --duration 87
		done
		sleep 5
		t=$(on vm-farm "date +%s.%N")
		node_power start "$victim"; wait_node "$victim"
		for b in 2 3; do
			r=$(load_wait vm-farm "b$b"); o=$(outage "$RESULTS/tl-b$b.txt" "$t"); s=$(stream_wait vm-farm "s$b")
			record "ms/服务器重新加入/$victim/块$b/新连接" "$(jq -c --argjson o "$o" '{ok, errors, err_mismatch} + {outage: $o}' <<<"$r")"
			record "ms/服务器重新加入/$victim/块$b/长连接" "$s"
			check "S $victim 重新加入，块 $b：身份不符、失败的请求、断掉的长连接" "0 0 0" "$(fj "$r" .err_mismatch) $(fj "$r" .errors) $(fj "$s" .broken)"
		done
		wait_bgp || true
		check "S $victim 回来后内网核心上每个块又有 2 个下一跳，网关去内网也是 2 个" "2 2 2 2" \
			"$(nexthops rtr-core "$BLOCK2_INTRA") $(nexthops rtr-core "$BLOCK3_INTRA") $(nexthops gw-1 "$INTRANET_NET") $(nexthops gw-2 "$INTRANET_NET")"
	done
fi

if want G; then
	say "G 一台网关断电：gw-2（单元 2 的主用，承载块 3）"
	before
	fault_power ms/网关断电 gw-2
	check "G 块 2（单元 1）不受影响：失败数、身份不符数、断掉的长连接数" "0 0 0" "$(fj "$F_B2" '"\(.errors) \(.err_mismatch)"') $(fj "$F_S2" .broken)"
	check "G 块 3 的身份没有串" 0 "$(fj "$F_B3" .err_mismatch)"
	check "G 块 3 的新连接恢复了，中断不超过 $MAX_SWITCH 秒（实际 $(fj "$F_B3" '.outage.outage_s // "没有恢复"') 秒）" 是 "$(within "$(fj "$F_B3" .outage.outage_s)" "$MAX_SWITCH")"
	check "G 块 3 已有的长连接全部中断（数据面 A 的固有行为）" 60 "$(fj "$F_S3" .broken)"
	check "G 共享热备 gw-3 接管了单元 2：持有服务地址，通告块 3" "gw-3 $BLOCK3_INTRA" "$(unit_holders "$GATEWAY_VIP2") $(advertised gw-3)"
	check "G 两台服务器上块 3 的路由都改指向 gw-3 的隧道接口" "wg-g3 wg-g3" \
		"$(for s in "${MS_SERVERS[@]}"; do on "$s" "ip -4 route show $BLOCK3_INTRA | grep -o 'dev [a-z0-9-]*' | cut -d' ' -f2"; done | tr '\n' ' ' | sed 's/ $//')"
	check "G 接管后块 3 的来源不变" 100.67.0.5 "$(farm_get 10.3.0.5 "http://$INTRANET_IP:8090/" | field client)"

	say "G（续）gw-2 恢复，再把单元 2 正常切回"
	node_power start gw-2; wait_node gw-2
	for _ in $(seq 1 40); do [ "$(nexthops gw-2 "$INTRANET_NET")" = 2 ] && break; sleep 2; done
	sleep 5
	check "G gw-2 回来后是备用：不抢单元 2，不通告任何块，两条隧道和会话都已恢复" "gw-3 | 2" "$(unit_holders "$GATEWAY_VIP2") |$(advertised gw-2) $(bgp_up gw-2)"
	load_bg vm-farm back --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base 10.3.0.1 --src-count "$FARM_PER_BLOCK" --expect-base 100.67.0.1 --conns 300 --rate 300 --timeout 1000 --duration 25
	sleep 8
	t=$(on vm-farm "date +%s.%N")
	unit_release gw-3 U2
	r=$(load_wait vm-farm back); o=$(outage "$RESULTS/tl-back.txt" "$t")
	record "ms/网关正常切回/块3/新连接" "$(jq -c --argjson o "$o" '{ok, errors, err_mismatch} + {outage: $o}' <<<"$r")"
	echo "  正常切回：失败 $(fj "$r" .errors) 个请求，中断 $(fj "$o" '.outage_s // "没有恢复"') 秒"
	check "G 单元 2 切回 gw-2，gw-3 不再通告；切回期间身份没有串" "gw-2 | 0" "$(unit_holders "$GATEWAY_VIP2") |$(advertised gw-3) $(fj "$r" .err_mismatch)"
fi

if want L; then
	say "L 一条隧道不通、两端都活着：gw-1 到 vpn-server 的那条"
	before
	inj_link() { inject_nft gw-1 "iifname \"\$IF_WAN\" ip saddr ${SRV_WAN[vpn-server]} udp sport 51841 drop" "oifname \"\$IF_WAN\" ip daddr ${SRV_WAN[vpn-server]} udp dport 51841 drop"; }
	heal_link() { AT_HEAL="$(nexthops gw-1 "$INTRANET_NET") $(nexthops rtr-core "$BLOCK2_INTRA") $(bgp_up gw-1) $(bgp_up gw-2)"; heal_nft gw-1; }
	fault_window ms/单条隧道不通 20 inj_link heal_link
	both_ok "L 单条隧道不通" "$MAX_SRV"
	check "L 故障期间：gw-1 去内网只剩 1 个下一跳、会话剩 1 个；内网核心上块 2 只剩 1 个下一跳；gw-2 的两个会话不受影响" "1 1 1 2" "$AT_HEAL"
	check "L 单元没有换网关" "gw-1 gw-2" "$(unit_holders "$GATEWAY_VIP") $(unit_holders "$GATEWAY_VIP2")"
	for _ in $(seq 1 40); do [ "$(bgp_up gw-1)" = 2 ] && break; sleep 2; done
	check "L 恢复之后 gw-1 的两个会话都回来了" 2 "$(bgp_up gw-1)"
fi

# 有状态防火墙的两种放法。规则是同一套：已建立的连接放行，新连接只允许从虚拟机一侧发起，其余丢弃。
# 连接跟踪按“严格”的方式工作（不接受半路出现的连接），这是多数防火墙的做法；Linux 默认是宽松的，
# 宽松时一条已有的连接换一台防火墙后，只要虚拟机一侧先发包就会被重新认下来，测不出差别。
fw_on() { # 节点 朝内网方向的出口网卡变量名（在节点上展开）
	on "$1" ". /etc/lab/ifaces.env
/etc/lab/tune.sh conntrack
sysctl -qw net.netfilter.nf_conntrack_tcp_loose=0
nft delete table ip labfw 2>/dev/null
nft -f - <<NFT
table ip labfw {
	chain forwarding {
		type filter hook forward priority filter; policy drop;
		ct state established,related accept
		ct state new oifname \"\$$2\" accept
		counter comment \"dropped\"
	}
}
NFT"
}
fw_off() { local n; for n in "$@"; do on "$n" "nft delete table ip labfw 2>/dev/null; sysctl -qw net.netfilter.nf_conntrack_tcp_loose=1 2>/dev/null; true"; done; }
fw_dropped() { on "$1" "nft list chain ip labfw forwarding 2>/dev/null | grep -oE 'counter packets [0-9]+' | awk '{print \$3}'"; }

if want F; then
	say "F 共用一套有状态防火墙：放在内网核心上，两台服务器的流量都经过它"
	before
	fw_on rtr-core IF_INTRANET
	steady || true
	run_load "ms/防火墙/共用/块3" vm-farm 30 "$PATH_M" --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base 10.3.0.1 --src-count "$FARM_PER_BLOCK" \
		--expect-base 100.67.0.1 --conns 128 --threads 3
	check "F 共用防火墙下去程和回程在两台服务器之间任意分摊：失败数和身份不符数" "0 0" "$(fj "$LAST_LOAD" '"\(.errors) \(.err_mismatch)"')"
	fault_power ms/防火墙/共用/服务器断电 vpn-server-2
	both_ok "F 共用防火墙下 vpn-server-2 断电" "$MAX_SRV"
	node_power start vpn-server-2; wait_node vpn-server-2; wait_bgp || true
	fw_off rtr-core

	say "F 各自独立的防火墙（对照）：每台服务器上各一套，互相不知道对方的连接"
	before
	fw_on vpn-server IF_CORE_NET; fw_on vpn-server-2 IF_CORE_NET
	run_load "ms/防火墙/各自独立/块3" vm-farm 30 "$PATH_M" --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base 10.3.0.1 --src-count "$FARM_PER_BLOCK" \
		--expect-base 100.67.0.1 --conns 128 --threads 3 --timeout 1000
	pct=$(fj "$LAST_LOAD" '(100 * .errors / ([.ok + .errors, 1] | max)) | floor')
	ctrl "F 各自独立时回程从另一台服务器回来的连接不通：至少两成请求失败（实际 ${pct}%）" 是 "$(within 20 "$pct")"
	check "F 对照里身份没有串" 0 "$(fj "$LAST_LOAD" .err_mismatch)"
	echo "  两台服务器的防火墙丢掉的包：vpn-server $(fw_dropped vpn-server)，vpn-server-2 $(fw_dropped vpn-server-2)"

	say "F 退路：vpn-server 做主用、vpn-server-2 做备用（备用的那台把自己通告的路径加长），防火墙仍然各自独立"
	on vpn-server-2 "vtysh -c 'conf t' -c 'route-map STANDBY permit 10' -c 'set as-path prepend 65102 65102' -c 'exit' \
-c 'router bgp 65102' -c 'address-family ipv4 unicast' -c 'neighbor GATEWAYS route-map STANDBY out' -c 'neighbor $CORE_IP route-map STANDBY out' >/dev/null
vtysh -c 'clear bgp ipv4 unicast * soft out' >/dev/null"
	for _ in $(seq 1 30); do [ "$(nexthops rtr-core "$BLOCK3_INTRA") $(nexthops gw-2 "$INTRANET_NET")" = "1 1" ] && break; sleep 1; done
	check "F 内网核心和网关上都只剩经 vpn-server 的那一条" "1 1 ${SRV_CORE[vpn-server]}" "$(nexthops rtr-core "$BLOCK3_INTRA") $(nexthops gw-2 "$INTRANET_NET") $(on rtr-core "ip -4 route show $BLOCK3_INTRA | grep -oE 'via [0-9.]+' | cut -d' ' -f2")"
	sleep 3; steady || true
	run_load "ms/防火墙/各自独立/一主一备/块3" vm-farm 30 "$PATH_M" --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base 10.3.0.1 --src-count "$FARM_PER_BLOCK" \
		--expect-base 100.67.0.1 --conns 128 --threads 3
	check "F 一主一备时去程和回程走同一台，各自独立的防火墙下也通：失败数和身份不符数" "0 0" "$(fj "$LAST_LOAD" '"\(.errors) \(.err_mismatch)"')"
	fault_power ms/防火墙/各自独立/一主一备/主用断电 vpn-server
	for b in 2 3; do
		eval "fb=\$F_B$b; fs=\$F_S$b"
		check "F 主用的服务器断电，块 $b：身份没有串，新连接恢复了" "0 true" "$(fj "$fb" .err_mismatch) $(fj "$fb" .outage.recovered)"
		echo "  块 $b：新连接中断 $(fj "$fb" '.outage.outage_s // "没有恢复"') 秒；60 条长连接收到断开的 $(fj "$fs" .broken) 条，没断的此后发出而没有回来的数据共 $(fj "$fs" .lost_lines_on_survivors) 行（备用那台的防火墙不认得这些连接，包被悄悄丢掉，连接卡死而不是断开）"
	done
	node_power start vpn-server; wait_node vpn-server
	on vpn-server-2 "vtysh -c 'conf t' -c 'router bgp 65102' -c 'address-family ipv4 unicast' -c 'no neighbor GATEWAYS route-map STANDBY out' -c 'no neighbor $CORE_IP route-map STANDBY out' \
-c 'exit' -c 'exit' -c 'no route-map STANDBY' >/dev/null; vtysh -c 'clear bgp ipv4 unicast * soft out' >/dev/null"
	fw_off vpn-server vpn-server-2
	wait_bgp || true
	check "F 撤掉防火墙和一主一备之后，内网核心上每个块又有 2 个下一跳" "2 2" "$(nexthops rtr-core "$BLOCK2_INTRA") $(nexthops rtr-core "$BLOCK3_INTRA")"
fi

if want M; then
	say "M 和迁移并存：vm-c 退回旧方式"
	before
	"$(dirname "$0")/41-rollback.sh" vm-c >/dev/null
	sleep 8
	check "M vm-c 经自己的隧道访问内网，来源是它的内网 IP" "${INTRA_IP[vm-c]}" "$(get vm-c "http://$INTRANET_IP:8080/" | field client)"
	check "M vm-c 的流量不经过 Egress 的处理（没有凭证）" 无 "$(get vm-c "http://$INTRANET_IP/" | field identity)"
	check "M vpn-server 上 vm-c 的 /32 指向 wg0" wg0 "$(on vpn-server "ip -4 route show ${INTRA_IP[vm-c]} | grep -o 'dev [a-z0-9-]*' | cut -d' ' -f2")"
	check "M 内网核心上 vm-c 的 /32 只指向 vpn-server（比两条等价的地址块路由更具体）" "${SRV_CORE[vpn-server]}" "$(on rtr-core "ip -4 route show ${INTRA_IP[vm-c]} | grep -oE 'via [0-9.]+' | cut -d' ' -f2")"
	r=$(get vm-a "http://$INTRANET_IP/")
	check "M 同一个块里已迁移的 vm-a 不受影响" "${INTRA_IP[vm-a]} vm-a" "$(echo "$r" | field client) $(echo "$r" | field identity)"
	for i in 1 2 3 4 5 6; do get vm-c "http://$INTRANET_IP:8080/" | field client; done | sort | uniq -c | sed 's/^/  vm-c 连发 6 次看到的来源：/'

	say "M（续）vm-c 重新迁移"
	"$(dirname "$0")/40-migrate.sh" vm-c >/dev/null
	sleep 5
	r=$(get vm-c "http://$INTRANET_IP/")
	check "M vm-c 迁移回来：来源不变，凭证由 Egress 注入" "${INTRA_IP[vm-c]} vm-c" "$(echo "$r" | field client) $(echo "$r" | field identity)"
	check "M vpn-server 和内网核心上 vm-c 的 /32 都没有了" "0 0" "$(on vpn-server "ip -4 route show ${INTRA_IP[vm-c]}/32 | wc -l") $(on rtr-core "ip -4 route show ${INTRA_IP[vm-c]}/32 | wc -l")"
fi

if want P; then
	say "P 主备之间互相听不到：gw-2 和 gw-3（这个形态下两台都通告同一个块，只测后果）"
	before
	inj_part() {
		inject_nft gw-2 'iifname "$IF_SVC_NET" ip saddr 10.1.255.13 drop' &
		inject_nft gw-3 'iifname "$IF_SVC_NET" ip saddr 10.1.255.12 drop' &
		wait
	}
	heal_part() { AT_HEAL="$(unit_holders "$GATEWAY_VIP2") | $(advertised gw-2) | $(advertised gw-3)"; heal_nft gw-2 gw-3; }
	fault_window ms/主备互相听不到 30 inj_part heal_part
	echo "  故障期间：持有单元 2 服务地址的、gw-2 通告的、gw-3 通告的：$AT_HEAL"
	check "P 块 2（单元 1）不受影响：失败数、身份不符数、断掉的长连接数" "0 0 0" "$(fj "$F_B2" '"\(.errors) \(.err_mismatch)"') $(fj "$F_S2" .broken)"
	check "P 块 3 的身份没有串" 0 "$(fj "$F_B3" .err_mismatch)"
	check "P 互通恢复之后块 3 的新连接自己恢复了" true "$(fj "$F_B3" .outage.recovered)"
	sleep 6
	check "P 互通恢复之后单元 2 只剩一台主用，只有它在通告块 3" 1 "$(( $(advertised gw-2 | grep -c "$BLOCK3_INTRA" || true) + $(advertised gw-3 | grep -c "$BLOCK3_INTRA" || true) ))"
fi

say "收尾"
fw_off rtr-core vpn-server vpn-server-2
heal_nft "${ALL_GATEWAYS[@]}"
units_home || true
wait_bgp || true
check "单元 1 在 gw-1、单元 2 在 gw-2" "gw-1 gw-2" "$(unit_holders "$GATEWAY_VIP") $(unit_holders "$GATEWAY_VIP2")"
check "块 2、块 3 的来源不变" "100.66.0.5 100.67.0.5" "$(farm_get 10.2.0.5 "http://$INTRANET_IP:8090/" | field client) $(farm_get 10.3.0.5 "http://$INTRANET_IP:8090/" | field client)"
finish
