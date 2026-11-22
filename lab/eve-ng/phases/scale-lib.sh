# 规模化形态和数据面 B 的部署函数：`. "$(dirname "$0")/scale-lib.sh"`（在 common.sh 之后）。
ALL_GATEWAYS=(gw-1 gw-2 gw-3)
RETURN_VIP3=10.1.255.202      # 块 3 的回程地址（SVC-NET 上），和块 3 的接入地址一起漂移
declare -A SVC_IP=([gw-1]=10.1.255.11 [gw-2]=10.1.255.12 [gw-3]=10.1.255.13)
declare -A GW_NUM=([gw-1]=1 [gw-2]=2 [gw-3]=3)
declare -A READY_IP=([gw-1]=10.1.255.111 [gw-2]=10.1.255.112 [gw-3]=10.1.255.113)   # 数据面 B 里网关的就绪地址

# gen_wg_keys <名字...>：state/wg/ 下没有的密钥对就生成（在 vpn-server 上生成后取回）。
gen_wg_keys() {
	local n
	mkdir -p "$STATE/wg"
	for n in "$@"; do
		[ -s "$STATE/wg/$n.key" ] && continue
		(umask 077; on vpn-server "wg genkey" > "$STATE/wg/$n.key")
		on vpn-server "echo '$(cat "$STATE/wg/$n.key")' | wg pubkey" > "$STATE/wg/$n.pub"
		echo "已生成密钥对 $n"
	done
}

# unit_holder <服务地址>：现在哪台网关持有这个单元的服务地址。
unit_holder() {
	local gw
	for gw in "${ALL_GATEWAYS[@]}"; do
		if on "$gw" "ip -4 addr show | grep -q ' $1/'" 2>/dev/null; then echo "$gw"; return; fi
	done
	echo 无
}
# unit_release <网关> <U1|U2>：让这台网关主动让出一个单元（keepalived 的 track_file），等别的网关接手后恢复成备用。
# 这是“正常切换”：只动一个单元，不影响这台网关上的另一个单元。
unit_release() {
	local gw=$1 unit=$2 vip i
	[ "$unit" = U1 ] && vip=$GATEWAY_VIP || vip=$GATEWAY_VIP2
	on "$gw" "echo 1 > /etc/lab/hold-$unit"
	for i in $(seq 1 20); do
		[ "$(unit_holder "$vip")" != "$gw" ] && break
		sleep 0.5
	done
	sleep 2
	on "$gw" "echo 0 > /etc/lab/hold-$unit"
}

# ---------- 回到基础形态 ----------
# reset_to_base：撤掉数据面 B 和多单元的东西，回到“一个单元、gw-1 主用 gw-2 备用”。
# 只做清理，gw-1、gw-2 的基础配置由 30-deploy-solution.sh 重新下发。节点不可达的忽略。
reset_to_base() {
	local n
	rm -f "$STATE/scale-on" "$STATE/b-on"
	for n in "${EGRESS_NODES[@]}"; do
		on "$n" '. /etc/lab/ifaces.env
systemctl disable -q --now nh-monitor.service 2>/dev/null
rm -f /etc/lab/egress-b-boot.sh
nft delete table ip egress_b 2>/dev/null
while ip rule del iif "$IF_SVC_NET" fwmark 123 lookup 100 2>/dev/null; do :; done
ip route del 10.200.0.0/16 2>/dev/null; true' 2>/dev/null || true
	done
	on vpn-server "systemctl disable -q --now nh-monitor.service 2>/dev/null
for i in 1 2 3; do systemctl disable -q --now wg-quick@wg-gw\$i 2>/dev/null; rm -f /etc/wireguard/wg-gw\$i.conf; done
ip route del $BLOCK3_INTRA 2>/dev/null; true" 2>/dev/null || true
	for n in "${ALL_GATEWAYS[@]}"; do
		on "$n" "systemctl disable -q --now gwb-health.service 2>/dev/null; rm -f /etc/systemd/system/gwb-health.service
systemctl disable -q --now wg-quick@wgb 2>/dev/null; rm -f /etc/wireguard/wgb.conf /etc/lab/gateway-b-boot.sh
nft delete table ip gwb 2>/dev/null; sysctl -qw net.ipv4.ip_forward=0; ip route del $BLOCK3_INTRA 2>/dev/null
systemctl stop wg-quick@wg0 wg-quick@wg1 2>/dev/null; rm -f /etc/wireguard/wg1.conf
# 多单元的隧道配置在路由表 100 里留着一条各单元共用的路由（停隧道时故意不删）。
# 基础形态的 wg0.conf 启动时要自己加这一条，表里已经有的话会报错、隧道起不来，所以这里清掉。
for t in 100 201 202 300; do ip route flush table \$t 2>/dev/null; done; true" 2>/dev/null || true
	done
	# gw-3 只在规模化形态里用，基础形态下让它闲着
	on gw-3 "systemctl disable -q --now keepalived.service envoy.service 2>/dev/null; systemctl stop wg-quick@wg0 2>/dev/null; true" 2>/dev/null || true
}

# ---------- 数据面 A 的规模化形态：多个网关单元加共享热备 ----------
# render_unit_conf <单元号>：从仓库的 wg-unit.conf 生成这个单元的隧道配置。
#   单元 1：密钥 gateway，  隧道 wg0，路由表 201，块 1（10.1.2.0/24）和块 2；
#   单元 2：密钥 gateway2，隧道 wg1，路由表 202，块 3。
render_unit_conf() {
	local key table n1 n2
	case $1 in
	1) key=gateway; table=201; n1=10.1.2.0/24; n2=$BLOCK2_REAL ;;
	2) key=gateway2; table=202; n1=$BLOCK3_REAL; n2="" ;;
	esac
	sed -e "s|<本单元私钥>|$(wgkey $key)|" -e "s|<本单元路由表>|$table|g" \
		-e "s|<VPN服务器公钥>|$(wgpub server)|" -e "s|<VPN服务器地址>|203.0.113.1|" \
		-e "s|<本单元的虚拟机网段1>|$n1|" -e "$([ -n "$n2" ] && echo "s|<本单元的虚拟机网段2>|$n2|" || echo '/<本单元的虚拟机网段2>/d')" \
		"$REPO/config/vpn-gateway/multi-unit/wg-unit.conf"
}

# deploy_scale_gateway <网关> <单元 1 的优先级> <单元 2 的优先级> <VRRP 通告间隔>
# 下发多单元的配置并启动 Envoy。keepalived 只装好配置，不在这里启动（启动顺序决定谁当主用，由调用方安排）。
deploy_scale_gateway() {
	local gw=$1 n
	for n in 1 2; do
		(umask 077; render_unit_conf $n > "$STATE/tmp")
		put_secret "$gw" "$STATE/tmp" "/etc/wireguard/wg$((n - 1)).conf"
	done
	rm -f "$STATE/tmp"
	put "$gw" "$REPO/config/vpn-gateway/multi-unit/envoy.yaml" /etc/envoy/envoy.yaml
	put "$gw" "$REPO/config/vpn-gateway/multi-unit/vpngw.nft" /etc/lab/vpngw.nft
	put "$gw" "$FILES/gateway-filter.nft" /etc/lab/gwfilter.nft.in
	put "$gw" "$FILES/gateway-boot.sh" /etc/lab/boot.sh
	put "$gw" "$FILES/tune.sh" /etc/lab/tune.sh
	put "$gw" "$FILES/load-map.sh" /etc/lab/load-map.sh
	put "$gw" "$FILES/gateway-notify.sh" /etc/lab/notify.sh
	put "$gw" "$FILES/lab-boot.service" /etc/systemd/system/lab-boot.service
	put "$gw" "$FILES/envoy.service" /etc/systemd/system/envoy.service
	put "$gw" "$FILES/keepalived-units.conf" /etc/keepalived/keepalived.conf.in
	put "$gw" "$FILES/keepalived-stop.conf" /etc/systemd/system/keepalived.service.d/stop-tunnel.conf
	on "$gw" ". /etc/lab/ifaces.env
chmod 755 /etc/lab/boot.sh /etc/lab/notify.sh /etc/lab/tune.sh /etc/lab/load-map.sh
sed \"s/@SVCIF@/\$IF_SVC_NET/g\" /etc/lab/gwfilter.nft.in > /etc/lab/gwfilter.nft
sed -e \"s/@SVCIF@/\$IF_SVC_NET/g\" -e 's/@PRIO1@/$2/; s/@PRIO2@/$3/; s/@ADVERT@/$4/g' /etc/keepalived/keepalived.conf.in > /etc/keepalived/keepalived.conf
echo 0 > /etc/lab/hold-U1; echo 0 > /etc/lab/hold-U2
/usr/local/bin/envoy --mode validate -c /etc/envoy/envoy.yaml -l error >/dev/null 2>&1 || { echo '$gw：Envoy 配置没有通过校验'; exit 1; }
systemctl daemon-reload
systemctl enable -q lab-boot.service envoy.service keepalived.service
systemctl restart lab-boot.service && systemctl restart envoy.service
sleep 1; echo \"$gw：envoy \$(systemctl is-active envoy.service)，映射表 \$(wc -l < /etc/lab/vm2intra) 条\""
}

# gen_farm_mappings：生成 vm-farm 模拟的身份的地址分配表（块 2、块 3 各 FARM_PER_BLOCK 个）。
gen_farm_mappings() {
	python3 - "$FARM_PER_BLOCK" > "$STATE/mappings-farm" <<'PY'
import ipaddress, sys
n = int(sys.argv[1])
for real, intra in (("10.2.0.0", "100.66.0.0"), ("10.3.0.0", "100.67.0.0")):
    r, i = int(ipaddress.ip_address(real)), int(ipaddress.ip_address(intra))
    for k in range(1, n + 1):
        print(ipaddress.ip_address(r + k), ipaddress.ip_address(i + k))
PY
}

# farm_get <源地址> <URL>：从 vm-farm 以指定的源地址发一个请求，输出响应体；失败输出 {"error": …}。
farm_get() {
	local out
	out=$(on vm-farm "curl -s -m ${TIMEOUT:-6} --interface $1 '$2' || echo '{\"error\": \"curl 失败\"}'" 2>/dev/null) || true
	echo "${out:-{\"error\": \"没有结果\"\}}"
}

# ---------- 数据面 B：地址转换在 Egress 上，网关只转发 ----------
# 实验里走数据面 B 的是块 3。要让一个块由多台网关同时承载，引入了三样最小的改动：
#   1. 每台网关自己一对密钥、自己一条到 VPN 服务器的隧道（网关上叫 wgb，服务器上叫 wg-gw<N>），一直建着；
#   2. VPN 服务器上对块 3 的回程是多条等价路由，每条指向一台网关的隧道；Egress 上去内网的路由同样指向三台网关；
#   3. 两处各跑一个探测脚本（nh-monitor.py），把不通的下一跳从路由里摘掉。
#      VPN 服务器探测网关在隧道里的地址；Egress 探测网关的就绪地址（10.1.255.111 到 .113），
#      网关只在自己的隧道通、转发已打开时才配上它（gateway-b-health.sh）。
# 隧道两端的探测地址：第 N 台网关是 100.65.N.2，服务器一侧是 100.65.N.1。
B_BLOCK_REAL=$BLOCK3_REAL
B_BLOCK_INTRA=$BLOCK3_INTRA
NH_INTERVAL=${NH_INTERVAL:-0.2}   # 探测间隔（秒）；连续 3 次没有应答判为不通

nh_config() { # 前缀 然后每个下一跳三个参数：名字 "下一跳的写法" 探测地址
	local prefix=$1; shift
	python3 - "$NH_INTERVAL" "$prefix" "$@" <<'PY'
import json, sys
a = sys.argv[3:]
hops = [{"name": a[i], "nexthop": a[i + 1], "probe": a[i + 2]} for i in range(0, len(a), 3)]
print(json.dumps({"interval": float(sys.argv[1]), "fall": 3, "rise": 3, "routes": [{"prefix": sys.argv[2], "nexthops": hops}]}, ensure_ascii=False, indent=1))
PY
}
install_nh_monitor() { # 节点 配置文件
	put "$1" "$FILES/nh-monitor.py" /usr/local/bin/nh-monitor.py
	put "$1" "$FILES/nh-monitor.service" /etc/systemd/system/nh-monitor.service
	put "$1" "$2" /etc/lab/nh-monitor.json
	on "$1" "printf 'net.ipv4.fib_multipath_hash_policy = 1\n' > /etc/sysctl.d/90-lab-b.conf; sysctl -q -p /etc/sysctl.d/90-lab-b.conf
systemctl daemon-reload; systemctl enable -q nh-monitor.service; systemctl restart nh-monitor.service"
}

deploy_b_server() {
	local gw n
	for gw in "${ALL_GATEWAYS[@]}"; do
		n=${GW_NUM[$gw]}
		(umask 077; sed -e "s|<VPN服务器私钥>|$(wgkey server)|" -e "s|<本接口的端口，每台网关一个>|$((51820 + n))|" \
			-e "s|<服务器隧道地址>|100.65.$n.1|" -e "s|<该网关公钥>|$(wgpub "gwb-$n")|" \
			-e "s|<走数据面B的内网地址块>|$B_BLOCK_INTRA|" -e "s|<该网关隧道地址>|100.65.$n.2|" \
			"$REPO/config/dataplane-b/vpn-server-wg-gw.conf" > "$STATE/tmp")
		put_secret vpn-server "$STATE/tmp" "/etc/wireguard/wg-gw$n.conf"
		on vpn-server "systemctl enable -q wg-quick@wg-gw$n; systemctl restart wg-quick@wg-gw$n"
	done
	rm -f "$STATE/tmp"
	nh_config "$B_BLOCK_INTRA" gw-1 "dev wg-gw1" 100.65.1.2 gw-2 "dev wg-gw2" 100.65.2.2 gw-3 "dev wg-gw3" 100.65.3.2 > "$STATE/tmp"
	# 先把块 3 从单元 2 的对端里拿掉（wg0 上不再有它的路由），再让探测脚本接管这条路由
	apply_server_conf
	install_nh_monitor vpn-server "$STATE/tmp"
	rm -f "$STATE/tmp"
}

deploy_b_gateway() { # 网关 两台 Egress 在 SVC-NET 上的网卡地址（逗号分隔）
	local gw=$1 n=${GW_NUM[$1]}
	(umask 077; sed -e "s|<本网关私钥>|$(wgkey "gwb-$n")|" -e "s|<本网关隧道地址>|100.65.$n.2|" \
		-e "s|<走数据面B的内网地址块>|$B_BLOCK_INTRA|g" -e "s|<VPN服务器公钥>|$(wgpub server)|" \
		-e "s|<VPN服务器地址>|203.0.113.1|" -e "s|<本网关在服务器上的端口>|$((51820 + n))|" \
		-e "s|<服务器隧道地址>|100.65.$n.1|" "$REPO/config/dataplane-b/gateway-wgb.conf" > "$STATE/tmp")
	put_secret "$gw" "$STATE/tmp" /etc/wireguard/wgb.conf
	put "$gw" "$REPO/config/dataplane-b/gateway-b.nft" /etc/lab/gateway-b.nft.in
	printf 'add element ip gwb b_intra { %s }\nadd element ip gwb egress_mac { %s }\n' "$B_BLOCK_INTRA" "$2" > "$STATE/tmp"
	put "$gw" "$STATE/tmp" /etc/lab/gateway-b-sets.nft
	sed "s|@RETURN_ROUTES@|$B_BLOCK_INTRA $RETURN_VIP3|" "$FILES/gateway-b-boot.sh" > "$STATE/tmp"
	put "$gw" "$STATE/tmp" /etc/lab/gateway-b-boot.sh
	rm -f "$STATE/tmp"
	put "$gw" "$FILES/gateway-b-health.sh" /etc/lab/gateway-b-health.sh
	cat > "$STATE/tmp" <<UNIT
[Unit]
Description=Lab dataplane B gateway readiness address
After=lab-boot.service
StartLimitIntervalSec=0

[Service]
ExecStart=/etc/lab/gateway-b-health.sh 100.65.$n.1 ${READY_IP[$gw]}
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT
	put "$gw" "$STATE/tmp" /etc/systemd/system/gwb-health.service
	rm -f "$STATE/tmp"
	# 隧道不设成开机自启：由 gateway-b-boot.sh 在转发就绪之后启动
	on "$gw" ". /etc/lab/ifaces.env
sed \"s/@SVCIF@/\$IF_SVC_NET/g\" /etc/lab/gateway-b.nft.in > /etc/lab/gateway-b.nft
chmod 755 /etc/lab/gateway-b-boot.sh /etc/lab/gateway-b-health.sh
systemctl daemon-reload; systemctl disable -q wg-quick@wgb 2>/dev/null; systemctl stop wg-quick@wgb 2>/dev/null
/etc/lab/gateway-b-boot.sh
systemctl enable -q gwb-health.service; systemctl restart gwb-health.service
sleep 2; echo \"$gw：隧道 wgb \$(ip link show wgb >/dev/null 2>&1 && echo 已启动 || echo 没有启动)，转发已打开，就绪地址 \$(ip -4 addr show | grep -q ' ${READY_IP[$gw]}/' && echo 已配上 || echo 还没有)\""
}

deploy_b_egress() { # Egress 节点
	local eg=$1 args=() gw
	put "$eg" "$REPO/config/dataplane-b/egress-b.nft" /etc/lab/egress-b.nft.in
	printf 'add element ip egress_b b_real { %s }\nadd element ip egress_b b_intra { %s }\n' "$B_BLOCK_REAL" "$B_BLOCK_INTRA" > "$STATE/tmp"
	put "$eg" "$STATE/tmp" /etc/lab/egress-b-sets.nft
	cat "$STATE/mappings" "$STATE/mappings-farm" > "$STATE/tmp"
	put "$eg" "$STATE/tmp" /etc/lab/vm2intra
	put "$eg" "$FILES/load-map.sh" /etc/lab/load-map.sh
	put "$eg" "$FILES/egress-b-boot.sh" /etc/lab/egress-b-boot.sh
	local svcif; svcif=$(on "$eg" '. /etc/lab/ifaces.env; echo $IF_SVC_NET')
	# 下一跳是网关的网卡地址，探测的是它的就绪地址（隧道通、转发已打开时网关才配上）
	for gw in "${ALL_GATEWAYS[@]}"; do args+=("$gw" "via ${SVC_IP[$gw]} dev $svcif" "${READY_IP[$gw]}"); done
	nh_config 10.200.0.0/16 "${args[@]}" > "$STATE/tmp"
	on "$eg" ". /etc/lab/ifaces.env
sed -e \"s/@ACCIF@/\$IF_ACC_NET/g\" -e \"s/@SVCIF@/\$IF_SVC_NET/g\" /etc/lab/egress-b.nft.in > /etc/lab/egress-b.nft
chmod 755 /etc/lab/load-map.sh /etc/lab/egress-b-boot.sh
/etc/lab/egress-b-boot.sh && echo \"$eg：数据面 B 的规则已加载，映射表 \$(wc -l < /etc/lab/vm2intra) 条\""
	install_nh_monitor "$eg" "$STATE/tmp"
	rm -f "$STATE/tmp"
}

# ---------- 故障注入：同时观察块 2 和块 3 ----------
# fault_power <标签> <要断电的节点> [总秒数]
# 在 vm-farm 上同时跑四路：块 2、块 3 各一路“持续新建连接”（每秒 300 条，每条连接换一个身份，单次超时 1 秒，
# 核对内网服务看到的来源），各一组 60 条持续传输的长连接。第 10 秒给节点断电（EVE 停止节点）。
# 结束后输出每个块的：失败的请求数、新连接的中断时长、身份不符的个数、长连接断了几条、没断的最长卡了多久。
# 结果放在这些变量里：F_B2、F_B3（新连接）、F_S2、F_S3（长连接），都是 JSON。
fault_power() {
	local label=$1 victim=$2 secs=${3:-40} t_fault r b
	load_bg vm-farm b2 --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base 10.2.0.1 --src-count "$FARM_PER_BLOCK" --expect-base 100.66.0.1 \
		--conns 300 --rate 300 --timeout 1000 --duration "$secs"
	load_bg vm-farm b3 --target "$INTRANET_IP:$FAST_HTTP_L4" --src-base 10.3.0.1 --src-count "$FARM_PER_BLOCK" --expect-base 100.67.0.1 \
		--conns 300 --rate 300 --timeout 1000 --duration "$secs"
	stream_bg vm-farm s2 --target "$INTRANET_IP:$ECHO_PORT" --src-base 10.2.1.1 --count 60 --duration $((secs - 3))
	stream_bg vm-farm s3 --target "$INTRANET_IP:$ECHO_PORT" --src-base 10.3.1.1 --count 60 --duration $((secs - 3))
	sleep 10
	t_fault=$(on vm-farm "date +%s.%N")
	node_power stop "$victim"
	echo "  $victim 已断电（EVE 停止节点）"
	for b in 2 3; do
		r=$(load_wait vm-farm "b$b")
		r=$(jq -c --argjson o "$(outage "$RESULTS/tl-b$b.txt" "$t_fault")" '{ok, errors, err_mismatch, err_timeout, err_reset, err_connect} + {outage: $o}' <<<"$r")
		eval "F_B$b=\$r"
		record "$label/块$b/新连接" "$r"
		echo "  块 $b 新连接：$(jq -r '"成功 \(.ok)，失败 \(.errors)，身份不符 \(.err_mismatch)；中断 \(.outage.outage_s // "没有恢复") 秒"' <<<"$r")"
	done
	for b in 2 3; do
		r=$(stream_wait vm-farm "s$b")
		eval "F_S$b=\$r"
		record "$label/块$b/长连接" "$r"
		echo "  块 $b 长连接：$(jq -r '"\(.conns) 条里断了 \(.broken) 条；没断的最长卡了 \(.max_gap) 秒，卡过 0.3 秒以上的 \(.stalled_over_300ms) 条，丢的行数 \(.lost_lines_on_survivors)"' <<<"$r")"
	done
}
fj() { jq -r "$2" <<<"$1"; }   # 从上面的 JSON 里取一个值
