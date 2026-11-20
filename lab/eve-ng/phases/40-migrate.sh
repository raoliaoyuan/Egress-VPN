#!/usr/bin/env bash
# 把一台虚拟机从旧方式（自带隧道）迁移到新方案。用法：40-migrate.sh <虚拟机名>
# 三步，与文档“迁移步骤”一致：登记映射、停掉虚拟机上的 VPN 客户端并删除它的密钥、在 vpn-server 上删除它的 /32 peer。
set -euo pipefail
. "$(dirname "$0")/common.sh"
vm=${1:?用法：40-migrate.sh <虚拟机名>}
[ -n "${REAL_IP[$vm]:-}" ] || die "不认识的虚拟机 $vm"

say "1/3 在地址分配表登记 $vm：${REAL_IP[$vm]} 对应 ${INTRA_IP[$vm]}"
register "$vm"

say "2/3 停掉 $vm 上的 VPN 客户端，删除虚拟机上的隧道配置和私钥"
on "$vm" "systemctl disable -q --now wg-quick@wg0; rm -f /etc/wireguard/wg0.conf; ip link show wg0 >/dev/null 2>&1 && echo '隧道还在' || echo '隧道已停，去内网的流量改走默认路由（Egress）'"

say "3/3 在 vpn-server 上删除 $vm 的 /32 peer（旧密钥随之失效）"
sed -i "s/\b$vm\b//; s/  */ /g; s/^ //; s/ $//" "$STATE/legacy"
apply_server_conf
echo "$vm 已迁移。仍在用旧方式的虚拟机：$(cat "$STATE/legacy" | tr -s ' ' | sed 's/^$/无/')"
