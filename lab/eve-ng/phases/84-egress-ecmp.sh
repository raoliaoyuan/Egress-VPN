#!/usr/bin/env bash
# 阶段 8.4：多台 Egress 之间做等价多路径（先执行 80-scale-a.sh；块 3 走数据面 A）。跑完自己恢复成按块分片。
# 按块分片时，每个块固定由一台 Egress 负责（接入地址漂移）。这里换一种接入方式做对比：
# 两台 Egress 同时处理所有块，接入路由器按连接（五元组）把虚拟机的流量分摊到两台上。
# 数据面 A 下这是可行的：两台 Egress 的配置本来就相同，任何一台都能处理任何一台虚拟机；
# 网关那一层不变，仍然按来源所在的块选单元。
#   - rtr-acc：三个块的默认路由改成两个下一跳（两台 Egress 的网卡地址），按五元组分流；
#     探测脚本（nh-monitor.py）每 0.2 秒探测每台 Egress 的就绪地址，连续 3 次没有应答就摘掉；
#   - 两台 Egress：就绪地址（egress-ready.sh），Envoy 和劫持规则都就绪才配上。
#   1 分摊和身份：两个块的每个身份都发请求，来源必须正确；同一台虚拟机的连接确实落在两台 Egress 上；
#   2 一台 Egress 断电：两个块各有多少长连接断掉、新连接多久恢复（和分片时“它负责的块全断、约 4 秒”对比）；
#   3 这台 Egress 回来、重新加入：已有的长连接有多少被重新分到它身上而断掉（增减实例时打扰无关的连接）。
# 通过的标准：身份不符始终是 0；断电后新连接的中断不超过 MAX_ECMP 秒（默认 3）。断掉多少条长连接只记录。
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/bench-lib.sh"
. "$(dirname "$0")/scale-lib.sh"
scale_on || die "还不是规模化形态，先执行 80-scale-a.sh"
b_on && die "块 3 现在走数据面 B；先执行 30-deploy-solution.sh 和 80-scale-a.sh"
MAX_ECMP=${MAX_ECMP:-3}
ECMP_TABLE=110
declare -A ACC_IP=([egress-1]=10.1.254.20 [egress-2]=10.1.254.21)
declare -A EG_READY=([egress-1]=10.1.254.120 [egress-2]=10.1.254.121)
BLOCKS="10.1.2.0/24 $BLOCK2_REAL $BLOCK3_REAL"
PATH_E="vm-farm rtr-acc egress-1 egress-2 gw-1 gw-2 vpn-server intranet-svc"
hops() { on rtr-acc "ip route show table $ECMP_TABLE 2>/dev/null | grep -oE 'via [0-9.]+' | cut -d' ' -f2 | sort | tr '\n' ' '" | sed 's/ $//'; }

ecmp_off() { # 恢复成按块分片：撤掉 rtr-acc 上的规则、路由表和探测脚本，撤掉 Egress 上的就绪地址
	local eg b
	on rtr-acc "systemctl disable -q --now nh-monitor.service 2>/dev/null
for b in $BLOCKS; do while ip rule del from \$b lookup $ECMP_TABLE 2>/dev/null; do :; done; done
ip route flush table $ECMP_TABLE 2>/dev/null; sysctl -qw net.ipv4.fib_multipath_hash_policy=0; rm -f /etc/sysctl.d/90-lab-b.conf; true" || true
	for eg in "${EGRESS_NODES[@]}"; do
		on "$eg" "systemctl disable -q --now egress-ready.service 2>/dev/null; rm -f /etc/systemd/system/egress-ready.service; systemctl daemon-reload; true" 2>/dev/null || true
	done
}
trap ecmp_off EXIT

say "部署：两台 Egress 的就绪地址，rtr-acc 上的等价多路径"
ecmp_off
for eg in "${EGRESS_NODES[@]}"; do
	put "$eg" "$FILES/egress-ready.sh" /etc/lab/egress-ready.sh
	cat > "$STATE/tmp" <<UNIT
[Unit]
Description=Lab Egress readiness address
After=lab-boot.service envoy.service
StartLimitIntervalSec=0

[Service]
ExecStart=/etc/lab/egress-ready.sh ${EG_READY[$eg]}
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT
	put "$eg" "$STATE/tmp" /etc/systemd/system/egress-ready.service
	on "$eg" "chmod 755 /etc/lab/egress-ready.sh; systemctl daemon-reload; systemctl enable -q egress-ready.service; systemctl restart egress-ready.service"
done
accif=$(on rtr-acc '. /etc/lab/ifaces.env; echo $IF_ACC_NET')
nh_config "default table $ECMP_TABLE" egress-1 "via ${ACC_IP[egress-1]} dev $accif" "${EG_READY[egress-1]}" \
	egress-2 "via ${ACC_IP[egress-2]} dev $accif" "${EG_READY[egress-2]}" > "$STATE/tmp"
install_nh_monitor rtr-acc "$STATE/tmp"
rm -f "$STATE/tmp"
for _ in $(seq 1 20); do [ "$(hops)" = "${ACC_IP[egress-1]} ${ACC_IP[egress-2]}" ] && break; sleep 0.5; done
# 规则的优先级比按块分片的那几条（1000）高，撤掉这几条就回到分片
on rtr-acc "for b in $BLOCKS; do ip rule add from \$b lookup $ECMP_TABLE priority 950; done"
check "rtr-acc 上三个块的默认路由有两个下一跳" "${ACC_IP[egress-1]} ${ACC_IP[egress-2]}" "$(hops)"

say "1 分摊和身份"
for spec in "2 10.2.0.1 100.66.0.1" "3 10.3.0.1 100.67.0.1"; do
	set -- $spec
	run_load "ecmp/身份/块$1/四层" vm-farm 30 "$PATH_E" --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base "$2" --src-count "$FARM_PER_BLOCK" \
		--expect-base "$3" --conns 128 --threads 3
	check "1 块 $1：失败数和身份不符数" "0 0" "$(fj "$LAST_LOAD" '"\(.errors) \(.err_mismatch)"')"
	busy=$(tail -1 "$RESULTS/bench.jsonl" | jq -r '"\(.cpu["egress-1"].busy_pct > 20) \(.cpu["egress-2"].busy_pct > 20)"')
	check "1 块 $1 的流量两台 Egress 都在处理（CPU 都超过 20%）" "true true" "$busy"
done
srcs=$(for _ in $(seq 1 24); do farm_get 10.2.0.5 "http://$PUBLIC_IP:8080/" | field client; done | sort -u | tr '\n' ' ' | sed 's/ $//')
check "1 同一台虚拟机（10.2.0.5）访问公网，对端看到的来源在两台 Egress 的出口地址之间变化" "203.0.113.20 203.0.113.21" "$srcs"
for vm in "${VMS[@]}"; do
	r=$(for _ in 1 2 3 4 5 6 7 8; do get "$vm" "http://$INTRANET_IP/" | jq -r '"\(.client) \(.identity)"'; done | sort -u | tr '\n' ';')
	check "1 $vm 连发 8 个请求，来源和注入的凭证每次都是它自己的" "${INTRA_IP[$vm]} $vm;" "$r"
done

say "2 一台 Egress 断电：egress-2"
fault_power ecmp/Egress断电 egress-2
for b in 2 3; do
	eval "fb=\$F_B$b; fs=\$F_S$b"
	check "2 块 $b 的身份没有串" 0 "$(fj "$fb" .err_mismatch)"
	check "2 块 $b 的新连接恢复了，中断不超过 $MAX_ECMP 秒（实际 $(fj "$fb" '.outage.outage_s // "没有恢复"') 秒）" 是 "$(within "$(fj "$fb" .outage.outage_s)" "$MAX_ECMP")"
	echo "  块 $b：60 条长连接断了 $(fj "$fs" .broken) 条（落在 egress-2 上的那些），失败的请求 $(fj "$fb" .errors) 个"
done
check "2 rtr-acc 把 egress-2 从路由里摘掉了" "${ACC_IP[egress-1]}" "$(hops)"
on rtr-acc "journalctl -u nh-monitor.service --since -2min --no-pager -o cat | tail -3 | sed 's/^/  探测脚本：/'"

say "3 egress-2 回来，重新加入"
for b in 2 3; do
	load_bg vm-farm "b$b" --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base "10.$b.0.1" --src-count "$FARM_PER_BLOCK" --expect-base "100.6$((b + 4)).0.1" \
		--conns 300 --rate 300 --timeout 1000 --duration 80
	stream_bg vm-farm "s$b" --target "$INTRANET_IP:$ECHO_PORT" --src-base "10.$b.1.1" --count 60 --duration 77
done
sleep 5
t=$(on vm-farm "date +%s.%N")
node_power start egress-2; wait_node egress-2
for b in 2 3; do
	r=$(load_wait vm-farm "b$b")
	o=$(outage "$RESULTS/tl-b$b.txt" "$t")
	record "ecmp/Egress重新加入/块$b/新连接" "$(jq -c --argjson o "$o" '{ok, errors, err_mismatch} + {outage: $o}' <<<"$r")"
	s=$(stream_wait vm-farm "s$b")
	record "ecmp/Egress重新加入/块$b/长连接" "$s"
	echo "  块 $b：新连接失败 $(fj "$r" .errors) 个，中断 $(fj "$o" '.outage_s // "没有恢复"') 秒；60 条长连接断了 $(fj "$s" .broken) 条（被重新分到 egress-2 上的那些）"
	check "3 块 $b 重新加入期间身份没有串" 0 "$(fj "$r" .err_mismatch)"
done
check "3 egress-2 回到路由里" "${ACC_IP[egress-1]} ${ACC_IP[egress-2]}" "$(hops)"

say "恢复成按块分片"
ecmp_off
trap - EXIT
access_home || true
sleep 2
check "块 1、块 2 的接入地址在 egress-1，块 3 的在 egress-2" "egress-1 egress-2" "$(access_holder "$ACCESS_VIP") $(access_holder "$ACCESS_VIP3")"
check "rtr-acc 又把块 3 的流量交给块 3 的接入地址" "$ACCESS_VIP3" "$(on rtr-acc ". /etc/lab/ifaces.env; ip route get 10.200.5.6 from 10.3.0.9 iif \$IF_FARM_NET | grep -o 'via [0-9.]*' | cut -d' ' -f2")"
check "块 3 的来源不变" 100.67.0.5 "$(farm_get 10.3.0.5 "http://$INTRANET_IP:8090/" | field client)"
finish
