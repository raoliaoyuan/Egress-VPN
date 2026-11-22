#!/usr/bin/env bash
# 阶段 8.6：验证数据面 B（先执行 85-dataplane-b.sh；块 3 走数据面 B，块 1、块 2 走数据面 A）。
# 对应设计文档第 6 节列的五个验证点，性能那一条在 90-bench.sh 里测：
#   P1 连接池按源地址隔离：不同身份的请求不会落到别人的上游连接上；同一个身份的请求能复用连接；
#   P2 连接跟踪的五元组冲突：不分区时确实出现，分区之后消失；
#   P3 回程包交回本机的 Envoy：靠那条策略路由，去掉它就不通；和透明劫持的规则互不干扰；
#   P4 网关断电（gw-1）：同一台网关上，走数据面 A 的块 2 连接全断，走数据面 B 的块 3 长连接不断；
#   M  十万条映射在 Egress 上的加载时间；
#   E  一台 Egress 断电（egress-2）：块 3 由 egress-1 接管，回程跟着接入地址一起切换。
# 用法：86-b-verify.sh [P1 P2 P3 P4 M E 里的若干个，默认全部]
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/bench-lib.sh"
. "$(dirname "$0")/scale-lib.sh"
b_on || die "块 3 还没有走数据面 B，先执行 85-dataplane-b.sh"
SECTIONS=${*:-P1 P2 P3 P4 M E}
want() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }
has() { on "$1" "$2 >/dev/null 2>&1 && echo 有 || echo 无"; }
B3="--src-base 10.3.0.1 --src-count $FARM_PER_BLOCK --expect-base 100.67.0.1"
PATH_B="vm-farm rtr-acc egress-2 gw-1 gw-2 gw-3 vpn-server intranet-svc"

if want P1; then
	say "P1 连接池是否按源地址隔离"
	run_load "b/连接池/全部身份轮流、长连接" vm-farm 30 "$PATH_B" --target "$INTRANET_IP:$FAST_HTTP_L7" $B3 --conns 256 --threads 3 --reqs-per-conn 20
	check "P1 $FARM_PER_BLOCK 个身份轮流发请求（七层，每条连接 20 个请求）：失败数、身份不符数" "0 0" "$(fj "$LAST_LOAD" '"\(.errors) \(.err_mismatch)"')"
	run_load "b/连接池/8 个身份、128 条并发" vm-farm 20 "$PATH_B" --target "$INTRANET_IP:$FAST_HTTP_L7" --src-base 10.3.0.1 --src-count 8 --expect-base 100.67.0.1 --conns 128 --threads 3 --reqs-per-conn 5
	check "P1 8 个身份挤在 128 条并发连接上（上游连接大量复用）：失败数、身份不符数" "0 0" "$(fj "$LAST_LOAD" '"\(.errors) \(.err_mismatch)"')"
	run_load "b/连接池/全部身份、每个请求新建连接" vm-farm 30 "$PATH_B" --target "$INTRANET_IP:$FAST_HTTP_L7" $B3 --conns 256 --threads 3
	check "P1 每个请求新建连接、每条换一个身份：失败数、身份不符数" "0 0" "$(fj "$LAST_LOAD" '"\(.errors) \(.err_mismatch)"')"
	# 同一个身份连发 40 个请求，每个请求都是一条新的下游连接。看内网服务一共见到几个不同的来源端口：
	# 等于 40 说明每个请求都新建了上游连接；远小于 40 说明上游连接被复用了。
	ports() { on vm-farm "for i in \$(seq 1 40); do curl -s -m 3 --interface $1 http://$INTRANET_IP:$FAST_HTTP_L7/ | jq -r .cport; done | sort -u | wc -l"; }
	pa=$(ports 10.2.0.77); pb=$(ports 10.3.0.77)
	echo "  同一个身份的 40 个请求，内网服务见到的不同来源端口数：数据面 A（块 2）$pa 个，数据面 B（块 3）$pb 个"
	record "b/连接池/40个请求用了几条上游连接" "{\"dataplane_a\": $pa, \"dataplane_b\": $pb}"
	check "P1 数据面 A 下每个请求一条上游连接（对照）" 40 "$pa"
	if [ "$pb" -le 8 ]; then echo "通过：P1 数据面 B 下同一个身份的请求复用了上游连接（40 个请求只用了 $pb 条）"; else echo "失败：P1 数据面 B 下没有复用，用了 $pb 条"; FAILS=$((FAILS + 1)); fi
fi

if want P2; then
	say "P2 连接跟踪的五元组冲突"
	# 一个身份同时开 10000 条连接，源端口固定为 20000 到 29999，占掉 Egress 可选源端口范围的约两成。
	# Egress 的上游连接用同一个源地址、由内核另选源端口，约两成会选到虚拟机正在用的端口，
	# 这时两条连接的五元组相同。走四层端口，每条下游连接对应一条上游连接。
	collide() {
		# 清空连接跟踪表之前先等上游的空闲连接都关掉（空闲超时 10 秒）。不等的话，表被清空之后这些连接的
		# FIN 认不出属于哪条连接，不做地址转换，被出口检查丢掉，内网服务那一头就一直留着（实验里这样漏过两万多条）。
		sleep 14
		on egress-2 "conntrack -F >/dev/null 2>&1; true"; sleep 1
		run_load "b/五元组冲突/$1" vm-farm 20 "egress-2" --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base 10.3.0.9 --src-count 1 --expect-base 100.67.0.9 \
			--conns 10000 --threads 3 --reqs-per-conn 0 --rate 3000 --sport-base 20000 --timeout 3000
		sleep 5
	}
	# 去掉分区之前同样要等上游的空闲连接关完：分区一去掉，它们的关闭包就对不上原来的记录了
	sleep 14
	on egress-2 "nft flush chain ip egress_b zone_in; nft flush chain ip egress_b zone_out"
	collide "不分区（对照）"
	bad=$(fj "$LAST_LOAD" .errors)
	if [ "$bad" -gt 0 ]; then echo "对照成立：P2 不分区时冲突确实出现，失败 $bad 个请求（$(fj "$LAST_LOAD" '"超时 \(.err_timeout)，连接被断 \(.err_reset)，身份不符 \(.err_mismatch)"')）"
	else echo "失败：P2 对照组（不分区）没有出现失败"; FAILS=$((FAILS + 1)); fi
	sleep 14
	on egress-2 "/etc/lab/egress-b-boot.sh"
	collide "分区"
	check "P2 分区之后同样的压法：失败数、身份不符数" "0 0" "$(fj "$LAST_LOAD" '"\(.errors) \(.err_mismatch)"')"
	echo "  分区后成功 $(fj "$LAST_LOAD" .ok) 个请求，开了 $(fj "$LAST_LOAD" .opened) 条连接"
	sleep 14
	on egress-2 "conntrack -F >/dev/null 2>&1; true"
fi

if want P3; then
	say "P3 回程包能否交回 Egress 本机的 Envoy"
	check "P3 块 3 的请求正常（七层、四层）" "100.67.0.5 100.67.0.5" "$(farm_get 10.3.0.5 "http://$INTRANET_IP:8090/" | field client) $(farm_get 10.3.0.5 "http://$INTRANET_IP:8091/" | field client)"
	echo "  egress-2 上的反向路径检查：$(on egress-2 '. /etc/lab/ifaces.env; sysctl -n net.ipv4.conf.all.rp_filter net.ipv4.conf.$IF_SVC_NET.rp_filter | tr "\n" " "')（all、网关侧网卡；0 是不检查）"
	echo "  egress-2 上的策略路由：$(on egress-2 "ip rule show | grep 'fwmark 0x7b' | tr -s ' \t' ' '")"
	# 对照：去掉“带标记的回程包交给本机”那条策略路由，回程包就按目的地址（虚拟机的地址）转发走了。
	on egress-2 '. /etc/lab/ifaces.env; ip rule del iif $IF_SVC_NET fwmark 123 lookup 100'
	ctrl "P3 对照：去掉那条策略路由后，块 3 的请求" 无 "$(TIMEOUT=4 farm_get 10.3.0.5 "http://$INTRANET_IP:8091/" | field client)"
	on egress-2 '. /etc/lab/ifaces.env; ip rule add iif $IF_SVC_NET fwmark 123 lookup 100; conntrack -F >/dev/null 2>&1; true'
	# 对照期间内网服务没收到握手的最后一步，还会重发几秒，这些包在规则恢复后陆续回来。等它们过去再检查。
	sleep 8
	check "P3 恢复后块 3 的请求（连发 20 个，成功的个数）" 20 "$(on vm-farm "for i in \$(seq 1 20); do curl -s -m 3 --interface 10.3.0.5 http://$INTRANET_IP:8091/ | jq -r .client; done | grep -c '^100.67.0.5\$'")"
	# 和透明劫持的规则互不干扰：同一台 Egress 上，走数据面 A 的流量、去公网的流量照常
	check "P3 同一台 Egress 上块 3 去公网的流量照常（不带标记，不做地址映射）" 203.0.113.21 "$(farm_get 10.3.0.5 "http://$PUBLIC_IP:8080/" | field client)"
	check "P3 egress-1 也加载了数据面 B 的规则，块 2（数据面 A）照常" 100.66.0.5 "$(farm_get 10.2.0.5 "http://$INTRANET_IP:8090/" | field client)"
	r=$(get vm-a "http://$INTRANET_IP/")
	check "P3 块 1 的 vm-a（数据面 A）来源不变、凭证照常注入" "100.64.0.7 vm-a" "$(echo "$r" | field client) $(echo "$r" | field identity)"
	check "P3 vm-a 走客户端证书的端口照常" vm-a "$(get vm-a "http://$INTRANET_IP:9443/" | field client_cert)"
fi

if want P4; then
	say "P4 网关断电：gw-1（数据面 A 里是单元 1 的主用，承载块 2；数据面 B 里是承载块 3 的三台之一）"
	check "P4 开始前单元 1 在 gw-1，egress-2 上去内网的路由有三个下一跳" "gw-1 3" "$(unit_holder "$GATEWAY_VIP") $(on egress-2 "ip route show 10.200.0.0/16 | grep -c nexthop")"
	on egress-2 ": > /var/log/nh-monitor.log"; on vpn-server ": > /var/log/nh-monitor.log"
	fault_power b/网关断电 gw-1
	check "P4 块 3（数据面 B）已有的长连接：断掉的条数、没断的丢的行数" "0 0" "$(fj "$F_S3" '"\(.broken) \(.lost_lines_on_survivors)"')"
	check "P4 块 3 的身份没有串" 0 "$(fj "$F_B3" .err_mismatch)"
	check "P4 块 3 的新连接恢复了" true "$(fj "$F_B3" '.outage.recovered // true')"
	check "P4 块 2（数据面 A，同一台网关）已有的长连接全部中断（对照）" 60 "$(fj "$F_S2" .broken)"
	check "P4 块 2 的身份没有串" 0 "$(fj "$F_B2" .err_mismatch)"
	echo "  egress-2 的探测记录：$(on egress-2 "grep -v '^$' /var/log/nh-monitor.log | tail -3 | cut -d' ' -f2- | paste -sd'|' - | sed 's#|# / #g'")"
	echo "  vpn-server 的探测记录：$(on vpn-server "grep -v '^$' /var/log/nh-monitor.log | tail -3 | cut -d' ' -f2- | paste -sd'|' - | sed 's#|# / #g'")"
	check "P4 断电后 egress-2 上去内网的路由剩两个下一跳" 2 "$(on egress-2 "ip route show 10.200.0.0/16 | grep -c nexthop")"
	check "P4 vpn-server 上块 3 的回程剩两个下一跳" 2 "$(on vpn-server "ip route show $B_BLOCK_INTRA | grep -c nexthop")"
	check "P4 单元 1 由共享热备 gw-3 接管（数据面 A）" gw-3 "$(unit_holder "$GATEWAY_VIP")"

	say "P4（续）gw-1 恢复：重新加入转发，块 3 的连接不受影响；再把单元 1 正常切回"
	load_bg vm-farm b3 --target "$INTRANET_IP:$FAST_HTTP_L4" $B3 --conns 300 --rate 300 --timeout 1000 --duration 80
	stream_bg vm-farm s3 --target "$INTRANET_IP:$ECHO_PORT" --src-base 10.3.1.1 --count 60 --duration 77
	sleep 3
	node_power start gw-1; wait_node gw-1; sleep 10
	unit_release gw-3 U1
	r=$(load_wait vm-farm b3); s=$(stream_wait vm-farm s3)
	record "b/网关恢复/块3/新连接" "$(jq -c '{ok, errors, err_mismatch}' <<<"$r")"; record "b/网关恢复/块3/长连接" "$s"
	check "P4 gw-1 重新加入期间，块 3 的新连接失败数、身份不符数、断掉的长连接数" "0 0 0" "$(fj "$r" '"\(.errors) \(.err_mismatch)"') $(fj "$s" .broken)"
	echo "  期间成功 $(fj "$r" .ok) 个请求；长连接最长卡了 $(fj "$s" .max_gap) 秒"
	check "P4 恢复后 egress-2 上的路由回到三个下一跳，单元 1 回到 gw-1" "3 gw-1" "$(on egress-2 "ip route show 10.200.0.0/16 | grep -c nexthop") $(unit_holder "$GATEWAY_VIP")"
fi

if want M; then
	say "M 十万条映射在 Egress 上的加载时间（在 egress-1 上测，它现在不负责块 3）"
	check "M 块 3 的接入地址不在 egress-1 上" egress-2 "$(access_holder "$ACCESS_VIP3")"
	m=$(on egress-1 '
slab() { awk "/^Slab:/ {print \$2}" /proc/meminfo; }
now() { date +%s.%N; }
d() { awk "BEGIN { printf \"%.3f\", $1 - $2 }"; }
nft flush map ip egress_b vm2intra; sleep 1
s0=$(slab); t0=$(now); /etc/lab/load-map.sh egress_b; t1=$(now); sleep 1; s1=$(slab)
t2=$(now); /etc/lab/load-map.sh egress_b; t3=$(now)
echo "{\"entries\": $(wc -l < /etc/lab/vm2intra), \"load_empty_s\": $(d $t1 $t0), \"replace_full_s\": $(d $t3 $t2), \"slab_growth_kb\": $((s1 - s0))}"')
	echo "  $m"
	record "b/映射表/egress" "$m"
fi

if want E; then
	say "E 一台 Egress 断电：egress-2（负责块 3，数据面 B）"
	check "E 开始前接入地址各在其位" "egress-1 egress-2" "$(access_holder "$ACCESS_VIP") $(access_holder "$ACCESS_VIP3")"
	fault_power b/Egress断电 egress-2
	check "E 块 2（egress-1，数据面 A）不受影响：失败数、身份不符数、断掉的长连接数" "0 0 0" "$(fj "$F_B2" '"\(.errors) \(.err_mismatch)"') $(fj "$F_S2" .broken)"
	check "E 块 3 的身份没有串" 0 "$(fj "$F_B3" .err_mismatch)"
	check "E 块 3 的新连接恢复了" true "$(fj "$F_B3" .outage.recovered)"
	check "E 块 3 的接入地址和回程地址都由 egress-1 接管" "egress-1 有" "$(access_holder "$ACCESS_VIP3") $(has egress-1 "ip -4 addr show | grep -q ' $RETURN_VIP3/'")"
	check "E 接管后块 3 仍走数据面 B，来源不变" 100.67.0.5 "$(farm_get 10.3.0.5 "http://$INTRANET_IP:8090/" | field client)"
	say "E（续）egress-2 恢复，自己把块 3 拿回去"
	load_bg vm-farm back --target "$INTRANET_IP:$FAST_HTTP_L4" $B3 --conns 300 --rate 300 --timeout 1000 --duration 80
	t=$(on vm-farm "date +%s.%N")
	node_power start egress-2; wait_node egress-2
	r=$(load_wait vm-farm back)
	o=$(outage "$RESULTS/tl-back.txt" "$t")
	record "b/Egress恢复后抢回/块3/新连接" "$(jq -c --argjson o "$o" '{ok, errors, err_mismatch} + {outage: $o}' <<<"$r")"
	echo "  egress-2 抢回块 3：失败 $(fj "$r" .errors) 个请求，中断 $(fj "$o" '.outage_s // "没有恢复"') 秒"
	check "E 块 3 的接入地址回到 egress-2" egress-2 "$(access_holder "$ACCESS_VIP3")"
	check "E 抢回期间身份没有串，之后块 3 的请求正常" "0 100.67.0.5" "$(fj "$r" .err_mismatch) $(farm_get 10.3.0.5 "http://$INTRANET_IP:8091/" | field client)"
fi
finish
