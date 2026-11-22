#!/usr/bin/env bash
# 阶段 2：复现现状。可以重复执行，用来把实验重置回现状。
#每台虚拟机自己运行 WireGuard 客户端，经 Egress 转发到 vpn-server，各自拿到一个内网 IP。
# Egress 透明劫持虚拟机的 TCP，对指定的服务注入凭证，但去往内网的流量已经在虚拟机里被封进隧道，Egress 处理不到。
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/scale-lib.sh"

say "WireGuard 密钥（在 vpn-server 上生成，取回 state/wg/，不进版本库）"
mkdir -p "$STATE/wg"; chmod 700 "$STATE/wg"
if [ ! -s "$STATE/wg/server.key" ]; then
	for n in server vm-a vm-b vm-c gateway; do
		on vpn-server "wg genkey" > "$STATE/wg/$n.key"
		on vpn-server "echo '$(cat "$STATE/wg/$n.key")' | wg pubkey" > "$STATE/wg/$n.pub"
	done
	chmod 600 "$STATE/wg"/*.key
	echo "已生成 5 对密钥"
else
	echo "沿用已有密钥"
fi

say "状态回到现状：三台虚拟机都用旧方式，映射表为空，没有网关 peer"
printf '%s\n' "${VMS[*]}" > "$STATE/legacy"
: > "$STATE/mappings"
rm -f "$STATE/gateway-on"
reset_to_base   # 部署过多单元或数据面 B 的话，先撤掉
(push_mappings >/dev/null 2>&1) || true   # 网关如果已经部署过，清空它的映射表；没部署过就跳过

say "vpn-server：每台虚拟机一个 /32 的 peer"
apply_server_conf

say "三台虚拟机：各自的 WireGuard 客户端"
for vm in "${VMS[@]}"; do
	install_vm_wg "$vm"
	on "$vm" "systemctl enable -q wg-quick@wg0; systemctl restart wg-quick@wg0; echo $vm wg0 已启动"
done
rm -f "$STATE/wg0.tmp"

say "Egress：透明劫持，只对指定的服务注入凭证（现状配置，没有网关）"
egress_files
egress_config baseline
echo "现状已搭好，用 21-check-baseline.sh 检查"
