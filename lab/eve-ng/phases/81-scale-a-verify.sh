#!/usr/bin/env bash
# 阶段 8.1：验证数据面 A 的规模化形态（先执行 80-scale-a.sh；块 3 走数据面 A）。
#   A 身份：块 2、块 3 的每个身份都发请求，内网服务看到的来源必须是这个身份的内网 IP，错一个都不行；
#   B 十万条映射：整表加载、整表替换、单条增删各要多久，占多少内存；
#   C 跨网段冒用源地址被接入路由器拦住；
#   D 一台网关断电（gw-2，单元 2 的主用）：只影响块 3；共享热备 gw-3 接管要多久；然后正常切回；
#   E 一台 Egress 断电（egress-2）：只影响块 3；egress-1 接管要多久；egress-2 恢复后自己把块 3 拿回去。
# 用法：81-scale-a-verify.sh [A B C D E 里的若干个，默认全部]
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/bench-lib.sh"
. "$(dirname "$0")/scale-lib.sh"
scale_on || die "还不是规模化形态，先执行 80-scale-a.sh"
b_on && die "块 3 现在走数据面 B；这个脚本验证的是数据面 A，先执行 30-deploy-solution.sh 和 80-scale-a.sh"
SECTIONS=${*:-A B C D E}
want() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }
has() { on "$1" "$2 >/dev/null 2>&1 && echo 有 || echo 无"; }
endpoint() { on vpn-server "wg show wg0 endpoints | grep '$(wgpub "$1")' | awk '{print \$2}' | cut -d: -f1"; }
PATH_A="vm-farm rtr-acc egress-1 egress-2 gw-1 gw-2 gw-3 vpn-server intranet-svc"

if want A; then
	say "A 身份：每个身份都发请求，核对内网服务看到的来源"
	for spec in "2 10.2.0.1 100.66.0.1" "3 10.3.0.1 100.67.0.1"; do
		set -- $spec
		for port in $FAST_HTTP_L7 $FAST_HTTP_L4; do
			layer=$([ "$port" = "$FAST_HTTP_L7" ] && echo 七层 || echo 四层)
			run_load "scale-a/身份/块$1/$layer" vm-farm 40 "$PATH_A" --target "$INTRANET_IP:$port" --src-base "$2" --src-count "$FARM_PER_BLOCK" \
				--expect-base "$3" --conns 128 --threads 3
			check "A 块 $1 经$layer：失败数和身份不符数" "0 0" "$(fj "$LAST_LOAD" '"\(.errors) \(.err_mismatch)"')"
			covered=$(fj "$LAST_LOAD" "if .opened >= $FARM_PER_BLOCK then \"全部 $FARM_PER_BLOCK 个\" else \"\(.opened) 个\" end")
			echo "  覆盖的身份：$covered"
		done
	done
fi

if want B; then
	say "B 十万条映射：加载时间和内存（在没有承载任何单元的 gw-3 上测）"
	check "B gw-3 现在没有承载任何单元" "无 无" "$(has gw-3 "ip link show wg0") $(has gw-3 "ip link show wg1")"
	m=$(on gw-3 '
mem() { awk "/MemAvailable/ {print \$2}" /proc/meminfo; }
slab() { awk "/^Slab:/ {print \$2}" /proc/meminfo; }
now() { date +%s.%N; }
d() { awk "BEGIN { printf \"%.3f\", $1 - $2 }"; }
n=$(wc -l < /etc/lab/vm2intra)
nft flush map ip vpngw vm2intra; sleep 1
m0=$(mem); s0=$(slab); t0=$(now)
/etc/lab/load-map.sh vpngw
t1=$(now); sleep 1; m1=$(mem); s1=$(slab)
t2=$(now); /etc/lab/load-map.sh vpngw; t3=$(now)                # 表里已经有全量时再整表替换一次
t4=$(now); nft -f /run/vm2intra.vpngw.nft; t5=$(now)            # 只算 nft 提交，不算生成文件
t6=$(now); nft add element ip vpngw vm2intra "{ 10.9.9.9 : 100.64.3.9 }"; t7=$(now)
nft delete element ip vpngw vm2intra "{ 10.9.9.9 : 100.64.3.9 }"; t8=$(now)
t9=$(now); nft get element ip vpngw vm2intra "{ 10.3.100.200 }" >/dev/null; t10=$(now)
echo "{\"entries\": $n, \"file_bytes\": $(stat -c %s /run/vm2intra.vpngw.nft), \"load_empty_s\": $(d $t1 $t0), \"replace_full_s\": $(d $t3 $t2), \"nft_commit_s\": $(d $t5 $t4), \"add_one_s\": $(d $t7 $t6), \"del_one_s\": $(d $t8 $t7), \"get_one_s\": $(d $t10 $t9), \"mem_avail_drop_kb\": $((m0 - m1)), \"slab_growth_kb\": $((s1 - s0)), \"elements_now\": $(nft list map ip vpngw vm2intra | grep -oE "[0-9.]+ : [0-9.]+" | wc -l)}"')
	echo "  $m"
	record "scale-a/映射表" "$m"
	check "B 整表加载后条数和地址分配表一致" "$(fj "$m" .entries)" "$(fj "$m" .elements_now)"
	echo "  从空表加载 $(fj "$m" .entries) 条：$(fj "$m" .load_empty_s) 秒；已有全量时整表原子替换：$(fj "$m" .replace_full_s) 秒（其中 nft 提交 $(fj "$m" .nft_commit_s) 秒）"
	echo "  单条登记 $(fj "$m" .add_one_s) 秒，单条注销 $(fj "$m" .del_one_s) 秒；内核内存（slab）增加 $(fj "$m" .slab_growth_kb) KB，可用内存减少 $(fj "$m" .mem_avail_drop_kb) KB"
	# 整表替换期间映射不中断：在承载块 3 的 gw-2 上一边反复整表替换，一边持续发请求
	load_bg vm-farm rep --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base 10.3.0.1 --src-count "$FARM_PER_BLOCK" --expect-base 100.67.0.1 --conns 64 --rate 500 --timeout 1000 --duration 20
	sleep 3
	on gw-2 'for i in 1 2 3 4 5 6; do /etc/lab/load-map.sh vpngw; sleep 1; done'
	r=$(load_wait vm-farm rep)
	check "B 承载流量的网关上连续 6 次整表替换，期间的失败数和身份不符数" "0 0" "$(fj "$r" '"\(.errors) \(.err_mismatch)"')"
	echo "  期间成功 $(fj "$r" .ok) 个请求"
fi

if want C; then
	say "C 跨网段冒用源地址"
	# vm-farm 冒用块 1 里 vm-a 的地址发 SYN（目的端口 4242，别人不会用）。接入路由器开了反向路径检查，应当到不了 Egress。
	spoof() {
		on egress-1 '. /etc/lab/ifaces.env; rm -f /tmp/spoof.pcap; timeout 6 tcpdump -ni $IF_ACC_NET -w /tmp/spoof.pcap "src host 10.1.2.3 and tcp dst port 4242" >/dev/null 2>&1 &'
		on vm-farm "sleep 1; python3 -c \"
import socket
for _ in range(3):
    s = socket.socket(); s.setsockopt(socket.IPPROTO_IP, 19, 1); s.bind(('10.1.2.3', 0)); s.settimeout(0.5)   # 19 是 IP_TRANSPARENT：允许用不属于本机的源地址发包
    try: s.connect(('$INTRANET_IP', 4242))
    except OSError: pass
    s.close()
\"; sleep 6"
		on egress-1 "tcpdump -nr /tmp/spoof.pcap 2>/dev/null | wc -l"
	}
	check "C vm-farm 冒用 vm-a 的地址，到达 Egress 的包数" 0 "$(spoof)"
	on rtr-acc '. /etc/lab/ifaces.env; sysctl -qw net.ipv4.conf.$IF_FARM_NET.rp_filter=0'
	n=$(spoof)
	on rtr-acc '. /etc/lab/ifaces.env; sysctl -qw net.ipv4.conf.$IF_FARM_NET.rp_filter=1'
	if [ "$n" -gt 0 ]; then echo "对照成立：关掉接入路由器的反向路径检查后，冒用的包到达了 Egress（$n 个）"; else echo "失败：对照组没有抓到包"; FAILS=$((FAILS + 1)); fi
	check "C 恢复检查后再次冒用" 0 "$(spoof)"
fi

if want D; then
	say "D 一台网关断电：gw-2（单元 2 的主用，承载块 3）"
	check "D 开始前单元 1 在 gw-1、单元 2 在 gw-2" "gw-1 gw-2" "$(unit_holder "$GATEWAY_VIP") $(unit_holder "$GATEWAY_VIP2")"
	fault_power scale-a/网关断电 gw-2
	check "D 块 2（单元 1）不受影响：失败数、身份不符数、断掉的长连接数" "0 0 0" "$(fj "$F_B2" '"\(.errors) \(.err_mismatch)"') $(fj "$F_S2" .broken)"
	check "D 块 3 的身份没有串" 0 "$(fj "$F_B3" .err_mismatch)"
	check "D 块 3 的新连接恢复了" true "$(fj "$F_B3" .outage.recovered)"
	check "D 块 3 已有的长连接全部中断（数据面 A 的固有行为）" 60 "$(fj "$F_S3" .broken)"
	check "D 共享热备 gw-3 接管了单元 2 的服务地址和隧道" "gw-3 有" "$(unit_holder "$GATEWAY_VIP2") $(has gw-3 "ip link show wg1")"
	check "D gw-3 没有启动单元 1 的隧道" 无 "$(has gw-3 "ip link show wg0")"
	check "D vpn-server 看到单元 2 改从 gw-3 接入，服务器配置没有改动" 203.0.113.13 "$(endpoint gateway2)"
	check "D 接管后块 3 的来源不变" 100.67.0.5 "$(farm_get 10.3.0.5 "http://$INTRANET_IP:8090/" | field client)"

	say "D（续）gw-2 恢复，再把单元 2 正常切回"
	node_power start gw-2; wait_node gw-2; sleep 8
	check "D gw-2 回来后是备用，不抢单元 2" gw-3 "$(unit_holder "$GATEWAY_VIP2")"
	check "D gw-2 开机后自动加载了全量映射表" "$(( $(wc -l < "$STATE/mappings") + $(wc -l < "$STATE/mappings-farm") ))" "$(on gw-2 "nft list map ip vpngw vm2intra | grep -oE '[0-9.]+ : [0-9.]+' | wc -l")"
	load_bg vm-farm back --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base 10.3.0.1 --src-count "$FARM_PER_BLOCK" --expect-base 100.67.0.1 --conns 300 --rate 300 --timeout 1000 --duration 25
	sleep 8
	t=$(on vm-farm "date +%s.%N")
	unit_release gw-3 U2
	r=$(load_wait vm-farm back)
	o=$(outage "$RESULTS/tl-back.txt" "$t")
	record "scale-a/网关正常切回/块3/新连接" "$(jq -c --argjson o "$o" '{ok, errors, err_mismatch} + {outage: $o}' <<<"$r")"
	echo "  正常切回：失败 $(fj "$r" .errors) 个请求，中断 $(fj "$o" '.outage_s // "没有恢复"') 秒"
	check "D 单元 2 切回 gw-2，gw-3 重新空闲" "gw-2 无 无" "$(unit_holder "$GATEWAY_VIP2") $(has gw-3 "ip link show wg0") $(has gw-3 "ip link show wg1")"
	check "D 切回期间身份没有串" 0 "$(fj "$r" .err_mismatch)"
fi

if want E; then
	say "E 一台 Egress 断电：egress-2（负责块 3）"
	check "E 开始前接入地址各在其位" "egress-1 egress-2" "$(access_holder "$ACCESS_VIP") $(access_holder "$ACCESS_VIP3")"
	fault_power scale-a/Egress断电 egress-2
	check "E 块 2（egress-1）不受影响：失败数、身份不符数、断掉的长连接数" "0 0 0" "$(fj "$F_B2" '"\(.errors) \(.err_mismatch)"') $(fj "$F_S2" .broken)"
	check "E 块 3 的身份没有串" 0 "$(fj "$F_B3" .err_mismatch)"
	check "E 块 3 的新连接恢复了" true "$(fj "$F_B3" .outage.recovered)"
	check "E 块 3 的接入地址由 egress-1 接管" egress-1 "$(access_holder "$ACCESS_VIP3")"
	check "E 接管后块 3 的来源不变（仍经单元 2）" 100.67.0.5 "$(farm_get 10.3.0.5 "http://$INTRANET_IP:8090/" | field client)"
	check "E 接管后块 3 访问公网，来源变成 egress-1 的地址" 203.0.113.20 "$(farm_get 10.3.0.5 "http://$PUBLIC_IP:8080/" | field client)"

	say "E（续）egress-2 恢复，自己把块 3 拿回去"
	load_bg vm-farm back --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base 10.3.0.1 --src-count "$FARM_PER_BLOCK" --expect-base 100.67.0.1 --conns 300 --rate 300 --timeout 1000 --duration 80
	t=$(on vm-farm "date +%s.%N")
	node_power start egress-2; wait_node egress-2
	r=$(load_wait vm-farm back)
	o=$(outage "$RESULTS/tl-back.txt" "$t")
	record "scale-a/Egress恢复后抢回/块3/新连接" "$(jq -c --argjson o "$o" '{ok, errors, err_mismatch} + {outage: $o}' <<<"$r")"
	echo "  egress-2 抢回块 3：失败 $(fj "$r" .errors) 个请求，中断 $(fj "$o" '.outage_s // "没有恢复"') 秒"
	check "E 块 3 的接入地址回到 egress-2" egress-2 "$(access_holder "$ACCESS_VIP3")"
	check "E 抢回期间身份没有串" 0 "$(fj "$r" .err_mismatch)"
fi
finish
