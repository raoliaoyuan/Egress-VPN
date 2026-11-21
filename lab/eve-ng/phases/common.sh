# 各阶段脚本的公共部分：`. "$(dirname "$0")/common.sh"`。
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
STATE="$LAB_DIR/state"
FILES="$LAB_DIR/files"
REPO="$(cd "$LAB_DIR/../.." && pwd)"
INTRANET_IP=10.200.5.6
PUBLIC_IP=203.0.113.80
GATEWAY_VIP=10.1.255.10
declare -A REAL_IP=([vm-a]=10.1.2.3 [vm-b]=10.1.2.4 [vm-c]=10.1.2.99)
declare -A INTRA_IP=([vm-a]=100.64.0.7 [vm-b]=100.64.0.8 [vm-c]=100.64.0.99)
VMS=(vm-a vm-b vm-c)
GATEWAY_BLOCK=100.64.0.0/22   # 网关单元 1 的内网地址块，所有虚拟机的内网 IP 都在里面
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
	cat <<CONF
[Interface]
PrivateKey = $(wgkey server)
Address = 100.64.3.254/22
ListenPort = 51820
CONF
	local vm
	for vm in $(cat "$STATE/legacy" 2>/dev/null); do
		printf '\n[Peer]\n# %s（旧方式：虚拟机自带隧道）\nPublicKey = %s\nAllowedIPs = %s/32\n' "$vm" "$(wgpub "$vm")" "${INTRA_IP[$vm]}"
	done
	if [ -f "$STATE/gateway-on" ]; then
		echo
		grep -v '^#' "$REPO/config/vpn-server/gateway-peer.conf" | sed "s|<网关单元1公钥>|$(wgpub gateway)|"
	fi
}
apply_server_conf() {
	render_server_conf > "$STATE/wg0.tmp"
	put vpn-server "$STATE/wg0.tmp" /etc/wireguard/wg0.conf
	rm -f "$STATE/wg0.tmp"
	on vpn-server 'chmod 600 /etc/wireguard/wg0.conf
if ip link show wg0 >/dev/null 2>&1; then wg syncconf wg0 <(wg-quick strip wg0); else systemctl enable -q --now wg-quick@wg0; fi
wg show wg0 allowed-ips | awk "{print \"  peer\", substr(\$1,1,8) \"…\", \$2}"'
}

# ---------- 地址映射（控制面）----------
# state/mappings 是地址分配表：每行“真实 IP 内网 IP”。push_mappings 把它下发到两台网关。
push_mappings() {
	touch "$STATE/mappings"
	local gw
	for gw in gw-1 gw-2; do
		put "$gw" "$STATE/mappings" /etc/lab/vm2intra 2>/dev/null || { echo "  $gw 不可达，跳过"; continue; }
		on "$gw" 'nft flush map ip vpngw vm2intra
while read -r real intra; do [ -n "$real" ] && nft add element ip vpngw vm2intra "{ $real : $intra }"; done < /etc/lab/vm2intra
echo "  $(hostname) 的映射表：$(nft list map ip vpngw vm2intra | grep -o "elements = {[^}]*}" || echo 空)"'
	done
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
	for gw in gw-1 gw-2; do on "$gw" "conntrack -D -s ${REAL_IP[$1]} >/dev/null 2>&1 || true" 2>/dev/null || true; done
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
# egress_files：Egress 上不随阶段变化的文件：服务单元、内核规则、内网服务的 CA、各虚拟机的客户端证书。
egress_files() {
	local vm
	put egress "$FILES/envoy.service" /etc/systemd/system/envoy.service
	put egress "$FILES/egress.nft" /etc/lab/egress.nft.in
	put egress "$STATE/tls/ca.pem" /etc/lab/intranet-ca.pem
	for vm in "${VMS[@]}"; do
		put egress "$STATE/tls/client-$vm.pem" "/etc/lab/client/$vm.pem"
		put_secret egress "$STATE/tls/client-$vm.key" "/etc/lab/client/$vm.key"
	done
	printf '#!/bin/bash\nnft -f /etc/lab/egress.nft\n' > "$STATE/boot.tmp"
	put egress "$STATE/boot.tmp" /etc/lab/boot.sh
	put egress "$FILES/lab-boot.service" /etc/systemd/system/lab-boot.service
	rm -f "$STATE/boot.tmp"
	on egress '. /etc/lab/ifaces.env
sed -e "s/@VMIF@/$IF_VM_NET/g" -e "s/@WANIF@/$IF_WAN/g" /etc/lab/egress.nft.in > /etc/lab/egress.nft
nft -f /etc/lab/egress.nft
chmod 700 /etc/lab/client
systemctl daemon-reload; systemctl enable -q envoy.service lab-boot.service'
}

# egress_config <baseline|solution> [给凭证的虚拟机，空格分隔，默认全部] [--unscoped|--redis-inject]
# 生成 Egress 的 Envoy 配置，在节点上校验通过后替换并重启。配置里有令牌，全程只有 root 能读。
egress_config() {
	local stage=$1 vms=${2-${VMS[*]}} vm
	local -a args=()
	for vm in $vms; do args+=(--vm "$vm=${REAL_IP[$vm]}"); done
	(umask 077; python3 "$FILES/gen-egress-envoy.py" "$stage" --state "$STATE" "${args[@]}" ${3:-} > "$STATE/envoy.tmp")
	put_secret egress "$STATE/envoy.tmp" /etc/envoy/envoy.new.yaml
	rm -f "$STATE/envoy.tmp"
	on egress 'if ! /usr/local/bin/envoy --mode validate -c /etc/envoy/envoy.new.yaml -l error > /tmp/envoy-validate.log 2>&1; then
	echo "新配置没有通过校验，保留原配置："; tail -5 /tmp/envoy-validate.log; rm -f /etc/envoy/envoy.new.yaml; exit 1
fi
mv /etc/envoy/envoy.new.yaml /etc/envoy/envoy.yaml
systemctl restart envoy.service
ports() { ss -ltn | grep -oE ":1500[67] " | sort -u | wc -l; }
for _ in $(seq 1 20); do [ "$(ports)" = 2 ] && break; sleep 0.5; done
echo "Egress 的 Envoy：$(systemctl is-active envoy.service)，监听端口 $(ports) 个"
[ "$(ports)" = 2 ]'
}
