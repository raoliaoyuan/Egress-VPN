#!/usr/bin/env bash
# 阶段 2：复现现状。每台虚拟机自己运行 WireGuard 客户端，经 Egress 转发到 vpn-server，各自拿到一个内网 IP。
# Egress 透明劫持虚拟机的 TCP 并注入凭证，但去往内网的流量已经在虚拟机里被封进隧道，Egress 处理不到。
set -euo pipefail
. "$(dirname "$0")/common.sh"

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

say "vpn-server：每台虚拟机一个 /32 的 peer"
{
	cat <<EOF
[Interface]
PrivateKey = $(wgkey server)
Address = 100.64.3.254/22
ListenPort = 51820
EOF
	for vm in vm-a vm-b vm-c; do
		cat <<EOF

[Peer]
# $vm
PublicKey = $(wgpub $vm)
AllowedIPs = ${INTRA_IP[$vm]}/32
EOF
	done
} > "$STATE/wg0.tmp"
put vpn-server "$STATE/wg0.tmp" /etc/wireguard/wg0.conf
on vpn-server "chmod 600 /etc/wireguard/wg0.conf; systemctl enable -q wg-quick@wg0; systemctl restart wg-quick@wg0; wg show wg0 | grep -c '^peer'"

say "三台虚拟机：各自的 WireGuard 客户端"
for vm in vm-a vm-b vm-c; do
	cat > "$STATE/wg0.tmp" <<EOF
[Interface]
PrivateKey = $(wgkey $vm)
Address = ${INTRA_IP[$vm]}/32

[Peer]
PublicKey = $(wgpub server)
Endpoint = 203.0.113.1:51820
AllowedIPs = 10.200.0.0/16
PersistentKeepalive = 25
EOF
	put "$vm" "$STATE/wg0.tmp" /etc/wireguard/wg0.conf
	on "$vm" "chmod 600 /etc/wireguard/wg0.conf; systemctl enable -q wg-quick@wg0; systemctl restart wg-quick@wg0; echo $vm wg0 已启动"
done
rm -f "$STATE/wg0.tmp"

say "Egress：透明劫持、注入凭证（现状配置，没有网关）"
python3 "$FILES/gen-egress-envoy.py" baseline "$(credential)" > "$STATE/envoy.tmp"
put egress "$STATE/envoy.tmp" /etc/envoy/envoy.yaml
put egress "$FILES/envoy.service" /etc/systemd/system/envoy.service
put egress "$FILES/egress.nft" /etc/lab/egress.nft.in
put egress "$STATE/tls/ca.pem" /etc/lab/intranet-ca.pem
rm -f "$STATE/envoy.tmp"
on egress '. /etc/lab/ifaces.env
sed -e "s/@VMIF@/$IF_VM_NET/g" -e "s/@WANIF@/$IF_WAN/g" /etc/lab/egress.nft.in > /etc/lab/egress.nft
nft -f /etc/lab/egress.nft
chmod 600 /etc/envoy/envoy.yaml
systemctl daemon-reload; systemctl enable -q envoy.service; systemctl restart envoy.service
sleep 2; systemctl is-active envoy.service; ss -ltn | grep -c ":1500[67]"'
egress_boot_persist
echo "现状已搭好，用 21-check-baseline.sh 检查"
