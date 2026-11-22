#!/usr/bin/env bash
# 阶段 3：部署新方案，但还不迁移任何虚拟机。
# 两台 VPN 网关原样使用仓库 config/vpn-gateway/ 下的三份配置（只替换密钥和服务器地址，映射表从空开始）；
# vpn-server 加入网关 peer；Egress 换成带网关上游的配置。完成后虚拟机仍走各自的旧隧道，行为应当不变。
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/scale-lib.sh"

say "基础形态：一个网关单元，gw-1 主用、gw-2 备用（部署过多单元或数据面 B 的话，先撤掉）"
reset_to_base
for gw in gw-1 gw-2; do on "$gw" "systemctl stop keepalived.service 2>/dev/null; true"; done

for gw in gw-1 gw-2; do
	say "$gw：WireGuard 配置、Envoy、nftables、入口过滤、keepalived"
	sed -e "s|<网关单元1私钥>|$(wgkey gateway)|" -e "s|<VPN服务器公钥>|$(wgpub server)|" \
		-e "s|<VPN服务器地址>|203.0.113.1|" "$REPO/config/vpn-gateway/wg0.conf" > "$STATE/tmp"
	put "$gw" "$STATE/tmp" /etc/wireguard/wg0.conf
	put "$gw" "$REPO/config/vpn-gateway/envoy.yaml" /etc/envoy/envoy.yaml
	grep -v 'elements = ' "$REPO/config/vpn-gateway/vpngw.nft" > "$STATE/tmp"   # 映射表从空开始，由控制面登记
	put "$gw" "$STATE/tmp" /etc/lab/vpngw.nft
	put "$gw" "$FILES/gateway-filter.nft" /etc/lab/gwfilter.nft.in
	put "$gw" "$FILES/gateway-boot.sh" /etc/lab/boot.sh
	put "$gw" "$FILES/tune.sh" /etc/lab/tune.sh
	put "$gw" "$FILES/load-map.sh" /etc/lab/load-map.sh
	put "$gw" "$FILES/gateway-notify.sh" /etc/lab/notify.sh
	put "$gw" "$FILES/lab-boot.service" /etc/systemd/system/lab-boot.service
	put "$gw" "$FILES/envoy.service" /etc/systemd/system/envoy.service
	put "$gw" "$FILES/keepalived.conf" /etc/keepalived/keepalived.conf.in
	put "$gw" "$FILES/keepalived-stop.conf" /etc/systemd/system/keepalived.service.d/stop-tunnel.conf
	rm -f "$STATE/tmp"
	prio=100; [ "$gw" = gw-1 ] && prio=150
	on "$gw" ". /etc/lab/ifaces.env
chmod 600 /etc/wireguard/wg0.conf; chmod 755 /etc/lab/boot.sh /etc/lab/notify.sh /etc/lab/tune.sh /etc/lab/load-map.sh
sed \"s/@SVCIF@/\$IF_SVC_NET/g\" /etc/lab/gwfilter.nft.in > /etc/lab/gwfilter.nft
sed -e \"s/@SVCIF@/\$IF_SVC_NET/g\" -e 's/@PRIO@/$prio/' /etc/keepalived/keepalived.conf.in > /etc/keepalived/keepalived.conf
systemctl daemon-reload
systemctl enable -q lab-boot.service envoy.service keepalived.service
systemctl restart lab-boot.service && systemctl restart envoy.service && systemctl restart keepalived.service
sleep 2; echo \"envoy \$(systemctl is-active envoy.service)，keepalived \$(systemctl is-active keepalived.service)\""
	# 先让 gw-1 当上主用，再启动 gw-2，这样 gw-2 一开始就是备用。
	if [ "$gw" = gw-1 ]; then
		for _ in $(seq 1 15); do
			on gw-1 "ip -4 addr show | grep -q '$GATEWAY_VIP/'" && break
			sleep 1
		done
	fi
done
push_mappings

say "vpn-server：加入网关 peer（整块地址）"
touch "$STATE/gateway-on"
apply_server_conf

say "Egress：换成带网关上游的配置"
egress_files
egress_config solution

say "检查"
sleep 3
check "gw-1 持有服务地址" 有 "$(on gw-1 "ip -4 addr show | grep -q '$GATEWAY_VIP/' && echo 有 || echo 无")"
check "gw-1 的隧道已启动" 有 "$(on gw-1 "ip link show wg0 >/dev/null 2>&1 && echo 有 || echo 无")"
check "gw-2 没有服务地址" 无 "$(on gw-2 "ip -4 addr show | grep -q '$GATEWAY_VIP/' && echo 有 || echo 无")"
check "gw-2 的隧道没有启动" 无 "$(on gw-2 "ip link show wg0 >/dev/null 2>&1 && echo 有 || echo 无")"
check "gw-1 能经隧道到内网服务" 通 "$(on gw-1 "ping -c2 -W2 -I 100.64.0.1 $INTRANET_IP >/dev/null 2>&1 && echo 通 || echo 不通")"
check "vpn-server 看到网关从 gw-1 接入" 203.0.113.11 "$(on vpn-server "wg show wg0 endpoints | grep '$(wgpub gateway)' | awk '{print \$2}' | cut -d: -f1")"
finish
