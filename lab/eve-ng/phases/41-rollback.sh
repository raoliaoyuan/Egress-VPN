#!/usr/bin/env bash
# 把一台已迁移的虚拟机回退到旧方式。用法：41-rollback.sh <虚拟机名>
# 与文档一致：在 vpn-server 上恢复它的 /32 peer，重新启动它的 VPN 客户端，再从映射表删除它的记录。
set -euo pipefail
. "$(dirname "$0")/common.sh"
vm=${1:?用法：41-rollback.sh <虚拟机名>}
[ -n "${REAL_IP[$vm]:-}" ] || die "不认识的虚拟机 $vm"

say "1/3 在 vpn-server 上恢复 $vm 的 /32 peer"
if ! grep -qw "$vm" "$STATE/legacy"; then
	echo "$(cat "$STATE/legacy") $vm" | sed 's/^ //' > "$STATE/legacy.new"
	mv "$STATE/legacy.new" "$STATE/legacy"
fi
apply_server_conf

say "2/3 重新启动 $vm 上的 VPN 客户端"
on "$vm" "systemctl enable -q --now wg-quick@wg0; ip link show wg0 >/dev/null 2>&1 && echo '隧道已启动'"

say "3/3 从地址分配表删除 $vm 的记录"
unregister "$vm"
echo "$vm 已回退到旧方式"
