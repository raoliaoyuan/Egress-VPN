#!/usr/bin/env bash
# 阶段 8.2：数据面 A 规模化形态下，断电以外的故障（先执行 80-scale-a.sh；块 3 走数据面 A）。
# 故障都注入在 gw-2（单元 2 的主用，承载块 3）上，同时观察块 2（单元 1，不应受影响）和块 3。
#   K 转发进程停掉：gw-2 的 Envoy 停了，节点还在；
#   T 只断隧道：gw-2 到 VPN 服务器的隧道两个方向都不通，节点和 Envoy 都正常。
#     先做对照（健康检查只看进程，也就是原来的做法），再做正式的（健康检查看隧道）；
#   U 单方向丢包：只丢 VPN 服务器发给 gw-2 的隧道报文，gw-2 发出去的照常；
#   I 主用在服务网段上被隔离：gw-2 在 Egress 一侧的网卡收发都不通，到 VPN 服务器的网卡正常。
#     先做对照（不检查够不够得着 Egress），再做正式的；
#   P 主备之间互相听不到：gw-2 和 gw-3 之间的包互相丢掉，两台和 Egress、和 gw-1 都还通。
#     这是设计里没有解决的情况，这里只测出实际后果，不设通过的标准（身份不能串、恢复后要能自己收敛除外）。
# 通过的标准写成了数字：接管类的故障，块 3 新连接的中断不超过 MAX_SWITCH 秒（默认 8）。
# 用法：82-fault-a.sh [K T U I P 里的若干个，默认全部]
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/bench-lib.sh"
. "$(dirname "$0")/scale-lib.sh"
scale_on || die "还不是规模化形态，先执行 80-scale-a.sh"
b_on && die "块 3 现在走数据面 B；这个脚本验证的是数据面 A，先执行 30-deploy-solution.sh 和 80-scale-a.sh"
SECTIONS=${*:-K T U I P}
MAX_SWITCH=${MAX_SWITCH:-8}
want() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }

check_mode() { # on|off：三台网关上打开或关掉“看隧道”的健康检查（off 只用于对照）
	local gw
	for gw in "${ALL_GATEWAYS[@]}"; do
		if [ "$1" = off ]; then on "$gw" "touch /etc/lab/tunnel-check-off"; else on "$gw" "rm -f /etc/lab/tunnel-check-off"; fi
	done
}
# 恢复的函数都先记下恢复前一刻的状态：谁持有单元 2 的服务地址、谁启动着单元 2 的隧道。
snapshot() { AT_HEAL_VIP=$(unit_holders "$GATEWAY_VIP2"); AT_HEAL_TUN=$(tunnel_holders wg1); }

inj_envoy() { on gw-2 "systemctl stop envoy.service"; }
heal_envoy() { snapshot; on gw-2 "systemctl start envoy.service"; }
inj_tunnel() { inject_nft gw-2 'iifname "$IF_WAN" udp sport 51820 drop' 'oifname "$IF_WAN" udp dport 51820 drop'; }
inj_tunnel_return() { inject_nft gw-2 'iifname "$IF_WAN" udp sport 51820 drop'; }
inj_isolate() { inject_nft gw-2 'iifname "$IF_SVC_NET" drop' 'oifname "$IF_SVC_NET" drop'; }
inj_partition() {
	inject_nft gw-2 'iifname "$IF_SVC_NET" ip saddr 10.1.255.13 drop' &
	inject_nft gw-3 'iifname "$IF_SVC_NET" ip saddr 10.1.255.12 drop' &
	wait
}
heal_gw2() { snapshot; heal_nft gw-2; }
heal_partition() { snapshot; heal_nft gw-2 gw-3; }

before() { # 每一项开始前：两个单元各在其位，热备空闲，检查方式是正式的那种
	heal_nft gw-2 gw-3
	check_mode on
	on gw-2 "systemctl start envoy.service"
	units_home || die "单元没有回到第一顺位，不能开始"
	[ "$(tunnel_holders wg1)" = gw-2 ] || die "单元 2 的隧道不只在 gw-2 上：$(tunnel_holders wg1)"
	# 上一项（尤其是对照）可能让 VPN 服务器上的会话乱一阵。等两个块都连续 8 次访问成功再开始，
	# 否则上一项的余波会算到这一项头上。
	local ok=0 i
	for i in $(seq 1 120); do
		if [ "$(TIMEOUT=2 farm_get 10.2.0.9 "http://$INTRANET_IP:$FAST_HTTP_L4/" | field client)" = 100.66.0.9 ] \
			&& [ "$(TIMEOUT=2 farm_get 10.3.0.9 "http://$INTRANET_IP:$FAST_HTTP_L4/" | field client)" = 100.67.0.9 ]; then
			ok=$((ok + 1))
		else
			ok=0
		fi
		[ $ok -ge 8 ] && break
		sleep 0.5
	done
	[ $ok -ge 8 ] || die "开始前两个块没有稳定下来"
	sleep 2
}
unaffected() { check "$1 块 2（单元 1）不受影响：失败数、身份不符数、断掉的长连接数" "0 0 0" "$(fj "$F_B2" '"\(.errors) \(.err_mismatch)"') $(fj "$F_S2" .broken)"; }
took_over() { # 这一项的名字：热备接管了，并且在规定时间内
	check "$1 块 3 的身份没有串" 0 "$(fj "$F_B3" .err_mismatch)"
	check "$1 故障期间单元 2 的服务地址和隧道都只在共享热备 gw-3 上" "gw-3 gw-3" "$AT_HEAL_VIP $AT_HEAL_TUN"
	check "$1 块 3 的新连接恢复了，中断不超过 $MAX_SWITCH 秒（实际 $(fj "$F_B3" '.outage.outage_s // "没有恢复"') 秒）" 是 "$(within "$(fj "$F_B3" .outage.outage_s)" "$MAX_SWITCH")"
	check "$1 恢复之后 gw-2 是备用，不抢回单元 2" gw-3 "$(unit_holders "$GATEWAY_VIP2")"
}

if want K; then
	say "K 转发进程停掉：gw-2 的 Envoy"
	before
	fault_window scale-a/转发进程停掉 20 inj_envoy heal_envoy
	unaffected K
	took_over K
fi

if want T; then
	say "T 只断隧道（对照）：健康检查只看进程"
	before
	check_mode off
	fault_window scale-a/只断隧道/对照 20 inj_tunnel heal_gw2
	check_mode on
	unaffected T
	ctrl "T 只看进程时发现不了：故障期间单元 2 一直留在 gw-2 上" "gw-2 gw-2" "$AT_HEAL_VIP $AT_HEAL_TUN"
	ctrl "T 故障期间块 3 的请求至少九成失败（实际 $(fj "$F_B3" .window.fail_pct_during)%）" 是 "$(within 90 "$(fj "$F_B3" .window.fail_pct_during)")"
	check "T 对照里身份没有串" 0 "$(fj "$F_B3" .err_mismatch)"

	say "T 只断隧道：健康检查看隧道"
	before
	fault_window scale-a/只断隧道 20 inj_tunnel heal_gw2
	unaffected T
	took_over T
fi

if want U; then
	say "U 单方向丢包：只丢 VPN 服务器发给 gw-2 的隧道报文"
	before
	fault_window scale-a/隧道单向丢包 20 inj_tunnel_return heal_gw2
	unaffected U
	took_over U
fi

if want I; then
	say "I 主用在服务网段上被隔离（对照）：不检查够不够得着 Egress"
	before
	check_mode off
	fault_window scale-a/主用被隔离/对照 25 inj_isolate heal_gw2
	check_mode on
	ctrl "I 不检查时被隔离的 gw-2 一直占着单元 2 的隧道，和接管的 gw-3 同时启动着" "gw-2 gw-3" "$AT_HEAL_TUN"
	# 被隔离的网关听不到任何通告，连它平时不承载的单元 1 也抢：它启动了单元 1 的隧道，VPN 服务器上单元 1 的对端被它带走
	ctrl "I 不检查时连单元 1（块 2）也受影响：故障期间至少一半的请求失败（实际 $(fj "$F_B2" .window.fail_pct_during)%）" 是 "$(within 50 "$(fj "$F_B2" .window.fail_pct_during)")"
	echo "  对照里块 2：解除隔离后 $(fj "$F_B2" .window.clean_after_heal_s) 秒起不再失败"
	echo "  对照里块 3：故障期间失败 $(fj "$F_B3" .window.fail_pct_during)%，中断 $(fj "$F_B3" '.outage.outage_s // "没有恢复"') 秒"
	check "I 对照里身份没有串" 0 "$(fj "$F_B3" .err_mismatch)"
	sleep 5

	say "I 主用在服务网段上被隔离：够不着任何一台 Egress 就让出"
	before
	fault_window scale-a/主用被隔离 25 inj_isolate heal_gw2
	unaffected I
	check "I 块 3 的身份没有串" 0 "$(fj "$F_B3" .err_mismatch)"
	check "I 被隔离的 gw-2 自己停掉了单元 2 的隧道，隧道只在 gw-3 上" gw-3 "$AT_HEAL_TUN"
	check "I 块 3 的新连接恢复了，中断不超过 $MAX_SWITCH 秒（实际 $(fj "$F_B3" '.outage.outage_s // "没有恢复"') 秒）" 是 "$(within "$(fj "$F_B3" .outage.outage_s)" "$MAX_SWITCH")"
	sleep 5
	check "I 隔离解除后单元 2 只有一台主用" 1 "$(unit_holders "$GATEWAY_VIP2" | wc -w)"
fi

if want P; then
	say "P 主备之间互相听不到：gw-2 和 gw-3（设计里没有解决的情况，只测后果）"
	before
	fault_window scale-a/主备互相听不到 30 inj_partition heal_partition
	unaffected P
	echo "  故障期间持有单元 2 服务地址的：$AT_HEAL_VIP；启动着单元 2 隧道的：$AT_HEAL_TUN"
	record "scale-a/主备互相听不到/恢复前的状态" "$(jq -cn --arg vip "$AT_HEAL_VIP" --arg tun "$AT_HEAL_TUN" '{vip_holders: $vip, tunnel_holders: $tun}')"
	check "P 块 3 的身份没有串" 0 "$(fj "$F_B3" .err_mismatch)"
	check "P 互通恢复之后块 3 的新连接自己恢复了" true "$(fj "$F_B3" .outage.recovered)"
	sleep 5
	check "P 互通恢复之后单元 2 只剩一台主用、一条隧道" "1 1" "$(unit_holders "$GATEWAY_VIP2" | wc -w) $(tunnel_holders wg1 | wc -w)"
fi

say "收尾：两个单元挪回第一顺位"
heal_nft gw-2 gw-3
check_mode on
on gw-2 "systemctl start envoy.service"
units_home || true
sleep 3
check "单元 1 在 gw-1、单元 2 在 gw-2，gw-3 空闲" "gw-1 gw-2 gw-2" "$(unit_holders "$GATEWAY_VIP") $(unit_holders "$GATEWAY_VIP2") $(tunnel_holders wg1)"
check "块 3 的来源不变" 100.67.0.5 "$(farm_get 10.3.0.5 "http://$INTRANET_IP:8090/" | field client)"
check "块 2 的来源不变" 100.66.0.5 "$(farm_get 10.2.0.5 "http://$INTRANET_IP:8090/" | field client)"
finish
