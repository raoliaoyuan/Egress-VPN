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

credential() { cat "$STATE/credential"; }
wgkey() { cat "$STATE/wg/$1.key"; }
wgpub() { cat "$STATE/wg/$1.pub"; }

# get <虚拟机> <URL>：从虚拟机发一个 HTTP 请求，输出回显服务返回的 JSON；失败时输出 {"error": "..."}。
get() {
	local out n rc code
	# 节点上输出三段：响应体、HTTP 状态码、curl 的返回值，各占一行。
	out=$(on "$1" "curl -s -m ${TIMEOUT:-12} -w '\n%{http_code}' '$2'; rc=\$?; echo; echo rc=\$rc") || true
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

# cred：从回显服务的 JSON 里判断凭证头的情况，输出“已注入”“无”或“值不对”，不把凭证本身打印出来。
cred() {
	local v; v=$(field credential)
	if [ "$v" = "$(credential)" ]; then echo 已注入; elif [ "$v" = 无 ]; then echo 无; else echo 值不对; fi
}

# Egress 开机时重新加载内核规则。
egress_boot_persist() {
	printf '#!/bin/bash\nnft -f /etc/lab/egress.nft\n' > "$STATE/boot.tmp"
	put egress "$STATE/boot.tmp" /etc/lab/boot.sh
	put egress "$FILES/lab-boot.service" /etc/systemd/system/lab-boot.service
	rm -f "$STATE/boot.tmp"
	on egress "systemctl daemon-reload; systemctl enable -q lab-boot.service"
}
