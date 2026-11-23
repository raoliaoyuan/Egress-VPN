# 各阶段脚本的公共部分：`. "$(dirname "$0")/common.sh"`。
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
STATE="$LAB_DIR/state"
FILES="$LAB_DIR/files"
REPO="$(cd "$LAB_DIR/../.." && pwd)"
INTRANET_IP=10.200.5.6
PUBLIC_IP=203.0.113.80
GATEWAY_VIP=10.1.255.10       # 网关单元 1 的服务地址
GATEWAY_VIP2=10.1.255.30      # 网关单元 2 的服务地址（部署了多单元之后才有）
EGRESS_NODES=(egress-1 egress-2)   # 两台 Egress 的配置始终相同，按块分片、互为热备
ACCESS_VIP=10.1.254.101       # 块 1、块 2 的接入地址，平时在 egress-1 上
ACCESS_VIP3=10.1.254.102      # 块 3 的接入地址，平时在 egress-2 上
declare -A REAL_IP=([vm-a]=10.1.2.3 [vm-b]=10.1.2.4 [vm-c]=10.1.2.99)
declare -A INTRA_IP=([vm-a]=100.64.0.7 [vm-b]=100.64.0.8 [vm-c]=100.64.0.99)
VMS=(vm-a vm-b vm-c)
GATEWAY_BLOCK=100.64.0.0/22   # 块 1 的内网地址块，三台真实虚拟机的内网 IP 都在里面
# 块 2、块 3 是 vm-farm 模拟的虚拟机：真实地址和内网地址成段对应，第 i 个身份是两边的基地址各加 i。
BLOCK2_REAL=10.2.0.0/16; BLOCK2_INTRA=100.66.0.0/16
BLOCK3_REAL=10.3.0.0/16; BLOCK3_INTRA=100.67.0.0/16
FARM_PER_BLOCK=50000          # 每个模拟的块登记多少个身份（地址偏移 1 到这个数）

# 实验的形态由 state/ 下的标记文件记录：
#   scale-on：数据面 A 的规模化形态（两个网关单元加共享热备 gw-3），由 80-scale-a.sh 建立；
#   b-on：    块 3 走数据面 B（地址转换在 Egress 上，网关只转发），由 85-dataplane-b.sh 建立。
# 20-baseline.sh 和 30-deploy-solution.sh 会清掉这两个标记，回到只有一个单元、gw-1 主用 gw-2 备用的基础形态。
#   ms-on：   多台 VPN 服务器同时工作（每条邻接一个隧道接口，BGP 加 BFD），由 87-multi-server.sh 建立，叠在 scale-on 之上。
scale_on() { [ -f "$STATE/scale-on" ]; }
ms_on() { [ -f "$STATE/ms-on" ]; }
b_on() { [ -f "$STATE/b-on" ]; }
gateways() { if scale_on; then echo gw-1 gw-2 gw-3; else echo gw-1 gw-2; fi; }
SHARED_USER=svc-batch         # 内网服务上所有虚拟机共用的那个账号（静态凭证）
# 凭证的样子：令牌、静态口令，以及共用账号编码成 Authorization: Basic 之后固定不变的开头
# （“$SHARED_USER:lab-static-”的 base64）。检查“有没有泄露”时只按样子去找，不把凭证本身发到虚拟机上。
TOKEN_RE='lab-(token|static)-[0-9a-f]{24}|c3ZjLWJhdGNoOmxhYi1zdGF0aWMt'

wgkey() { cat "$STATE/wg/$1.key"; }
wgpub() { cat "$STATE/wg/$1.pub"; }

# get <虚拟机> <URL>：从虚拟机发一个 HTTP 请求，输出回显服务返回的 JSON；失败时输出 {"error": "..."}。
# 第三个参数可以再给 curl 加选项，例如 "-H 'Host: x'"。
get() {
	local out n rc code
	# 节点上输出三段：响应体、HTTP 状态码、curl 的返回值，各占一行。
	out=$(on "$1" "curl -s -m ${TIMEOUT:-12} ${3:-} -w '\n%{http_code}' '$2'; rc=\$?; echo; echo rc=\$rc") || true
	local -a L; mapfile -t L <<<"$out"; n=${#L[@]}
	[ "$n" -ge 2 ] || { echo '{"error": "节点没有返回结果"}'; return; }
	rc=${L[n-1]#rc=}; code=${L[n-2]}
	if [ "$rc" != 0 ]; then echo "{\"error\": \"curl 返回 $rc\"}"
	elif [ "$code" != 200 ]; then echo "{\"error\": \"HTTP $code\"}"
	else printf '%s\n' "${L[@]:0:n-2}"; fi
}
field() { jq -r ".$1 // \"无\"" 2>/dev/null || echo "无法解析"; }

FAILS=0
check() { # 说明 期望值 实际值
	if [ "$3" = "$2" ]; then
		echo "通过：$1（$3）"
	else
		echo "失败：$1，期望 $2，实际 $3"
		FAILS=$((FAILS + 1))
	fi
}
ctrl() { # 说明 期望值 实际值：对照实验，预期问题会出现
	if [ "$3" = "$2" ]; then
		echo "对照成立：$1（$3）"
	else
		echo "失败：$1，对照组期望 $2，实际 $3"
		FAILS=$((FAILS + 1))
	fi
}
leak() { # 说明 实际找到的凭证数：对照实验，预期能拿到
	if [ "$2" -gt 0 ]; then echo "对照成立：$1（拿到 $2 个凭证）"; else echo "失败：$1，对照组没有拿到凭证"; FAILS=$((FAILS + 1)); fi
}
body() { on "$1" "curl -s -m 8 ${3:-} '$2'" 2>/dev/null || true; }                          # 响应体原文
code() { on "$1" "curl -s -m 8 -o /dev/null -w '%{http_code}' ${3:-} '$2'" 2>/dev/null || true; }   # HTTP 状态码
tokens_in() { grep -oE "$TOKEN_RE" | sort -u | wc -l; }                                      # 输入里有几个不同的凭证
# scan_fs <节点>：扫一遍整个文件系统，列出含令牌样式或私钥标记的文件；含私钥标记的算出摘要，回来和上面的清单比对。
scan_fs() {
	on "$1" "LC_ALL=C grep -rlE --binary-files=text -e '$TOKEN_RE' -e 'BEGIN [A-Z ]*PRIVATE KEY' / \
--exclude-dir=proc --exclude-dir=sys --exclude-dir=dev --exclude-dir=run 2>/dev/null | while read -r f; do
	if LC_ALL=C grep -qE --binary-files=text '$TOKEN_RE' \"\$f\"; then echo \"token \$f\"; fi
	if LC_ALL=C grep -q --binary-files=text 'PRIVATE KEY' \"\$f\"; then echo \"key \$(sha256sum < \"\$f\" | cut -d' ' -f1)\"; fi
done; echo scanned" || true
}
finish() {
	echo
	if [ "$FAILS" = 0 ]; then echo "本阶段检查全部通过"; else echo "本阶段有 $FAILS 项检查失败"; fi
	exit "$FAILS"
}

# ---------- vpn-server 的 WireGuard 配置 ----------
# state/legacy 里列着还在用旧方式（自带隧道）的虚拟机；state/gateway-on 存在时加入网关 peer。
# 网关 peer 取自仓库的 config/vpn-server/gateway-peer.conf，只把公钥占位符换成实验里的公钥。
render_server_conf() {
	# 多台服务器的形态下，wg0 只留给旧方式的虚拟机：地址写成 /32，不让整个地址块的路由落在 wg0 上
	# （那样会盖住从各台网关的 BGP 通告学来的路由），也不在 wg0 上放网关的对端。
	cat <<CONF
[Interface]
PrivateKey = $(wgkey server)
Address = 100.64.3.254/$(ms_on && echo 32 || echo 22)
ListenPort = 51820
CONF
	local vm
	for vm in $(cat "$STATE/legacy" 2>/dev/null); do
		printf '\n[Peer]\n# %s（旧方式：虚拟机自带隧道）\nPublicKey = %s\nAllowedIPs = %s/32\n' "$vm" "$(wgpub "$vm")" "${INTRA_IP[$vm]}"
	done
	if [ -f "$STATE/gateway-on" ] && ! ms_on; then
		echo
		if scale_on; then
			# 多单元：单元 1 承载块 1、块 2；单元 2 承载块 3（块 3 改走数据面 B 之后，它不再属于任何单元）。
			grep -v '^#' "$REPO/config/vpn-server/gateway-peer.conf" | sed -e "s|<网关单元1公钥>|$(wgpub gateway)|" \
				-e "s|^AllowedIPs = .*|AllowedIPs = $GATEWAY_BLOCK, $BLOCK2_INTRA|"
			b_on || printf '\n[Peer]\n# VPN 网关单元 2\nPublicKey = %s\nAllowedIPs = %s\n' "$(wgpub gateway2)" "$BLOCK3_INTRA"
		else
			grep -v '^#' "$REPO/config/vpn-server/gateway-peer.conf" | sed "s|<网关单元1公钥>|$(wgpub gateway)|"
		fi
	fi
}
apply_server_conf() {
	render_server_conf > "$STATE/wg0.tmp"
	put vpn-server "$STATE/wg0.tmp" /etc/wireguard/wg0.conf
	rm -f "$STATE/wg0.tmp"
	# wg syncconf 只更新 peer，不动路由。块 2、块 3 不在 wg0 自己的网段里，它们指向 wg0 的路由要另外维护：
	# 该走 wg0 的补上，不该走的删掉（块 3 走数据面 B 时，它的路由由 nh-monitor 维护，这里不碰）。
	if ms_on; then
		# wg syncconf 不动路由：旧方式的虚拟机各自的 /32 路由在这里补上，已经迁移走的删掉。
		# 这些 /32 由 FRR 通告给内网核心，比网关通告的地址块更具体，回程仍然到这台服务器。
		local legacy_ips="" vm
		for vm in $(cat "$STATE/legacy" 2>/dev/null); do legacy_ips="$legacy_ips ${INTRA_IP[$vm]}"; done
		on vpn-server "chmod 600 /etc/wireguard/wg0.conf
if ip link show wg0 >/dev/null 2>&1; then wg syncconf wg0 <(wg-quick strip wg0); else systemctl enable -q --now wg-quick@wg0; fi
for r in \$(ip -4 route show dev wg0 | awk '\$1 ~ /^100\\.64\\./ {print \$1}'); do
	case ' $legacy_ips ' in *\" \$r \"*) ;; *) ip route del \$r dev wg0 ;; esac
done
for a in $legacy_ips; do ip route replace \$a/32 dev wg0; done
wg show wg0 allowed-ips | awk '{printf \"  peer %s…\", substr(\$1,1,8); for (i = 2; i <= NF; i++) printf \" %s\", \$i; print \"\"}'"
		return
	fi
	local want=""
	scale_on && [ -f "$STATE/gateway-on" ] && want="$BLOCK2_INTRA"
	scale_on && [ -f "$STATE/gateway-on" ] && ! b_on && want="$want $BLOCK3_INTRA"
	on vpn-server "chmod 600 /etc/wireguard/wg0.conf
if ip link show wg0 >/dev/null 2>&1; then wg syncconf wg0 <(wg-quick strip wg0); else systemctl enable -q --now wg-quick@wg0; fi
for b in $BLOCK2_INTRA $BLOCK3_INTRA; do
	case ' $want ' in
	*\" \$b \"*) ip route replace \$b dev wg0 ;;
	*) ip route show \$b | grep -q 'dev wg0' && ip route del \$b dev wg0 ;;
	esac
done
wg show wg0 allowed-ips | awk '{printf \"  peer %s…\", substr(\$1,1,8); for (i = 2; i <= NF; i++) printf \" %s\", \$i; print \"\"}'"
}

# ---------- 地址映射（控制面）----------
# state/mappings 是三台真实虚拟机的地址分配表：每行“真实 IP 内网 IP”。
# 规模化形态下再加上 state/mappings-farm（vm-farm 模拟的身份，由 80-scale-a.sh 生成）。
# push_mappings 把它们下发到每台做地址转换的节点：各台网关（数据面 A），以及部署了数据面 B 时的两台 Egress。
# 每个节点上用 load-map.sh 整表原子替换，中间没有“表是空的”那一刻。
push_mappings() {
	touch "$STATE/mappings"
	local node table targets=""
	cat "$STATE/mappings" > "$STATE/mappings.all"
	scale_on && [ -f "$STATE/mappings-farm" ] && cat "$STATE/mappings-farm" >> "$STATE/mappings.all"
	for node in $(gateways); do targets="$targets $node:vpngw"; done
	if b_on; then for node in "${EGRESS_NODES[@]}"; do targets="$targets $node:egress_b"; done; fi
	for node in $targets; do
		table=${node#*:}; node=${node%:*}
		put "$node" "$STATE/mappings.all" /etc/lab/vm2intra 2>/dev/null || { echo "  $node 不可达，跳过"; continue; }
		put "$node" "$FILES/load-map.sh" /etc/lab/load-map.sh
		on "$node" "chmod 755 /etc/lab/load-map.sh; /etc/lab/load-map.sh $table
n=\$(wc -l < /etc/lab/vm2intra)
if [ \$n -le 5 ]; then echo \"  \$(hostname) 的映射表：\$(nft list map ip $table vm2intra | grep -o 'elements = {[^}]*}' || echo 空)\"
else echo \"  \$(hostname) 的映射表：\$n 条\"; fi"
	done
	rm -f "$STATE/mappings.all"
}
register() { # 虚拟机名
	grep -q "^${REAL_IP[$1]} " "$STATE/mappings" 2>/dev/null || echo "${REAL_IP[$1]} ${INTRA_IP[$1]}" >> "$STATE/mappings"
	push_mappings
}
unregister() {
	touch "$STATE/mappings"
	sed -i "/^${REAL_IP[$1]} /d" "$STATE/mappings"
	push_mappings
	local gw
	for gw in $(gateways); do on "$gw" "conntrack -D -s ${REAL_IP[$1]} >/dev/null 2>&1 || true" 2>/dev/null || true; done
}

# ---------- 虚拟机上的旧隧道 ----------
# install_vm_wg <虚拟机>：把它的 WireGuard 客户端配置（含私钥）放到虚拟机上。只有旧方式需要。
install_vm_wg() {
	cat > "$STATE/wg0.tmp" <<CONF
[Interface]
PrivateKey = $(wgkey "$1")
Address = ${INTRA_IP[$1]}/32

[Peer]
PublicKey = $(wgpub server)
Endpoint = 203.0.113.1:51820
AllowedIPs = 10.200.0.0/16
PersistentKeepalive = 25
CONF
	put_secret "$1" "$STATE/wg0.tmp" /etc/wireguard/wg0.conf
	rm -f "$STATE/wg0.tmp"
}

# ---------- 内网服务的凭证表 ----------
# svc_table <bound|open>：生成内网服务的凭证表并下发。每行“摘要 身份 [允许的来源]”，服务端只拿到摘要。
# bound 是正常做法：每台虚拟机的令牌和口令只接受从它自己的内网 IP 发来，共用账号只接受从网关的地址块发来。
# open 不限定来源，只用于对照。
svc_table() {
	local vm
	digest() { tr -d '\n' < "$1" | sha256sum | cut -d' ' -f1; }
	{
		for vm in "${VMS[@]}"; do
			echo "$(digest "$STATE/creds/$vm.intranet-svc.token") $vm $([ "$1" = bound ] && echo "${INTRA_IP[$vm]}")"
			echo "$(digest "$STATE/creds/$vm.intranet-svc.pass") $vm $([ "$1" = bound ] && echo "${INTRA_IP[$vm]}")"
		done
		echo "$(digest "$STATE/creds/intranet-svc.shared") $SHARED_USER $([ "$1" = bound ] && echo "$GATEWAY_BLOCK")"
	} > "$STATE/creds/intranet-svc.hashes"
	put intranet-svc "$STATE/creds/intranet-svc.hashes" /etc/lab/tokens
}

# ---------- Egress ----------
# 两台 Egress 的配置始终相同：egress-1 平时负责块 1、块 2，egress-2 负责块 3，一台故障时另一台接管它的块，
# 所以每台都要预先有全部块的配置、凭证和证书。下面的函数都同时处理两台。

# egress_files：Egress 上不随阶段变化的文件：服务单元、内核参数、内核规则、内网服务的 CA、各虚拟机的客户端证书。
egress_files() {
	local eg vm
	for eg in "${EGRESS_NODES[@]}"; do
		put "$eg" "$FILES/envoy.service" /etc/systemd/system/envoy.service
		put "$eg" "$FILES/egress.nft" /etc/lab/egress.nft.in
		put "$eg" "$FILES/tune.sh" /etc/lab/tune.sh
		put "$eg" "$FILES/egress-boot.sh" /etc/lab/boot.sh
		put "$eg" "$FILES/lab-boot.service" /etc/systemd/system/lab-boot.service
		put "$eg" "$STATE/tls/ca.pem" /etc/lab/intranet-ca.pem
		for vm in "${VMS[@]}"; do
			put "$eg" "$STATE/tls/client-$vm.pem" "/etc/lab/client/$vm.pem"
			put_secret "$eg" "$STATE/tls/client-$vm.key" "/etc/lab/client/$vm.key"
		done
		on "$eg" '. /etc/lab/ifaces.env
sed -e "s/@VMIF@/$IF_ACC_NET/g" -e "s/@WANIF@/$IF_WAN/g" /etc/lab/egress.nft.in > /etc/lab/egress.nft
chmod 755 /etc/lab/tune.sh /etc/lab/boot.sh; chmod 700 /etc/lab/client
/etc/lab/boot.sh
systemctl daemon-reload; systemctl enable -q envoy.service lab-boot.service'
	done
}

# access_holder <接入地址>：现在哪台 Egress 持有这个接入地址。
access_holder() {
	local eg
	for eg in "${EGRESS_NODES[@]}"; do
		if on "$eg" "ip -4 addr show | grep -q ' $1/'" 2>/dev/null; then echo "$eg"; return; fi
	done
	echo 无
}
# access_home：等两个接入地址都回到各自的第一顺位（块 1、块 2 在 egress-1，块 3 在 egress-2）。
# keepalived 配成了抢占，Envoy 起来之后会自己回去，这里只是等。
access_home() {
	local i a b
	for i in $(seq 1 30); do
		a=$(access_holder "$ACCESS_VIP"); b=$(access_holder "$ACCESS_VIP3")
		[ "$a" = egress-1 ] && [ "$b" = egress-2 ] && return 0
		sleep 1
	done
	echo "接入地址没有回到第一顺位：$ACCESS_VIP 在 $a，$ACCESS_VIP3 在 $b"
	return 1
}

# egress_config <baseline|solution> [给凭证的虚拟机，空格分隔，默认全部] [--unscoped|--redis-inject]
# 生成 Egress 的 Envoy 配置，在节点上校验通过后替换并重启。配置里有令牌，全程只有 root 能读。
# 规模化形态下配置里按块选网关单元；块 3 走数据面 B 时再加上数据面 B 的监听器。两台 Egress 先后重启，不同时中断。
egress_config() {
	local stage=$1 vms=${2-${VMS[*]}} vm eg
	local -a args=()
	for vm in $vms; do args+=(--vm "$vm=${REAL_IP[$vm]}"); done
	if [ "$stage" = solution ]; then
		scale_on && args+=(--scale)
		b_on && args+=(--dataplane-b)
	fi
	(umask 077; python3 "$FILES/gen-egress-envoy.py" "$stage" --state "$STATE" "${args[@]}" ${3:-} > "$STATE/envoy.tmp")
	for eg in egress-2 egress-1; do
		put_secret "$eg" "$STATE/envoy.tmp" /etc/envoy/envoy.new.yaml
		on "$eg" 'if ! /usr/local/bin/envoy --mode validate -c /etc/envoy/envoy.new.yaml -l error > /tmp/envoy-validate.log 2>&1; then
	echo "新配置没有通过校验，保留原配置："; tail -5 /tmp/envoy-validate.log; rm -f /etc/envoy/envoy.new.yaml; exit 1
fi
mv /etc/envoy/envoy.new.yaml /etc/envoy/envoy.yaml
systemctl restart envoy.service
ports() { ss -ltn | grep -oE ":1500[67] " | sort -u | wc -l; }
for _ in $(seq 1 20); do [ "$(ports)" = 2 ] && break; sleep 0.5; done
echo "$(hostname) 的 Envoy：$(systemctl is-active envoy.service)，监听端口 $(ports) 个"
[ "$(ports)" = 2 ]' || { rm -f "$STATE/envoy.tmp"; return 1; }
	done
	rm -f "$STATE/envoy.tmp"
	access_home
}
