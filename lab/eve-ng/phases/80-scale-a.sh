#!/usr/bin/env bash
# 阶段 8：数据面 A 的规模化形态。开始前三台虚拟机都已迁移到新方案（没有的话这里先迁移）。可以重复执行。
#   - 网关层从“一个单元、一主一备”变成“两个单元加共享热备”：
#       单元 1（服务地址 10.1.255.10，块 1、块 2）：gw-1 第一顺位，gw-3 第二，gw-2 第三；
#       单元 2（服务地址 10.1.255.30，块 3）：      gw-2 第一顺位，gw-3 第二，gw-1 第三。
#     每个单元一对密钥、一条隧道，只有这个单元的主用启动它（设计文档里的“过渡做法”）；
#   - VPN 服务器上每个单元一个对端，各持有自己的地址块；
#   - 两台 Egress 的配置里按来源地址所在的块选单元；
#   - 登记 vm-farm 模拟的身份（块 2、块 3 各 FARM_PER_BLOCK 个，默认合计十万），下发到三台网关。
# 回到基础形态用 30-deploy-solution.sh。
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/scale-lib.sh"
GW_ADVERT=${GW_ADVERT:-1}   # 网关单元的 VRRP 通告间隔（秒）。热备在连续约 3 个间隔收不到通告后接管

[ -f "$STATE/ms-on" ] && die "现在是多台 VPN 服务器的形态；要回到这个形态，先执行 30-deploy-solution.sh"
say "准备：三台虚拟机都走新方案"
[ -f "$STATE/gateway-on" ] || die "还没有部署新方案，先执行 30-deploy-solution.sh"
for vm in $(cat "$STATE/legacy"); do "$(dirname "$0")/40-migrate.sh" "$vm" >/dev/null; echo "已迁移 $vm"; done
gen_wg_keys gateway2
touch "$STATE/scale-on"
rm -f "$STATE/b-on"

say "三台网关：两个单元的隧道配置、两个监听器的 Envoy、按隧道分开的规则、keepalived"
for gw in "${ALL_GATEWAYS[@]}"; do on "$gw" "systemctl stop keepalived.service 2>/dev/null; true"; done
deploy_scale_gateway gw-1 150 100 "$GW_ADVERT"
deploy_scale_gateway gw-2 100 150 "$GW_ADVERT"
deploy_scale_gateway gw-3 120 120 "$GW_ADVERT"
# 启动顺序决定谁当主用（都配成了不抢占）：先起 gw-1，它拿到两个单元；再起另外两台做备用；
# 然后让 gw-1 让出单元 2，备用里优先级最高的 gw-2 接手。
on gw-1 "systemctl restart keepalived.service"
for _ in $(seq 1 20); do [ "$(unit_holder "$GATEWAY_VIP2")" = gw-1 ] && break; sleep 1; done
on gw-2 "systemctl restart keepalived.service"
on gw-3 "systemctl restart keepalived.service"
sleep $((GW_ADVERT * 4 + 2))
unit_release gw-1 U2
echo "单元 1 在 $(unit_holder "$GATEWAY_VIP")，单元 2 在 $(unit_holder "$GATEWAY_VIP2")"

say "vpn-server：每个单元一个对端"
apply_server_conf

say "登记 vm-farm 模拟的身份：块 2、块 3 各 $FARM_PER_BLOCK 个"
gen_farm_mappings
echo "地址分配表：真实虚拟机 $(wc -l < "$STATE/mappings") 条，模拟的 $(wc -l < "$STATE/mappings-farm") 条"
push_mappings

say "两台 Egress：按块选网关单元"
egress_files
egress_config solution

say "检查"
has() { on "$1" "$2 >/dev/null 2>&1 && echo 有 || echo 无"; }
tunnels() { echo "$(has "$1" "ip link show wg0") $(has "$1" "ip link show wg1")"; }
endpoint() { on vpn-server "wg show wg0 endpoints | grep '$(wgpub "$1")' | awk '{print \$2}' | cut -d: -f1"; }
sleep 3
check "单元 1 的服务地址在 gw-1" gw-1 "$(unit_holder "$GATEWAY_VIP")"
check "单元 2 的服务地址在 gw-2" gw-2 "$(unit_holder "$GATEWAY_VIP2")"
check "gw-1 只启动了单元 1 的隧道（wg0、wg1）" "有 无" "$(tunnels gw-1)"
check "gw-2 只启动了单元 2 的隧道" "无 有" "$(tunnels gw-2)"
check "共享热备 gw-3 两条隧道都没有启动" "无 无" "$(tunnels gw-3)"
check "三台网关的映射表条数相同" "$(( $(wc -l < "$STATE/mappings") + $(wc -l < "$STATE/mappings-farm") ))" \
	"$(for gw in "${ALL_GATEWAYS[@]}"; do on "$gw" "nft list map ip vpngw vm2intra | grep -oE '[0-9.]+ : [0-9.]+' | wc -l"; done | sort -u | tr '\n' ' ' | sed 's/ $//')"
for vm in "${VMS[@]}"; do
	r=$(get "$vm" "http://$INTRANET_IP/")
	check "$vm（块 1）访问内网的来源不变、凭证照常注入" "${INTRA_IP[$vm]} $vm" "$(echo "$r" | field client) $(echo "$r" | field identity)"
done
check "vpn-server 看到单元 1 从 gw-1 接入" 203.0.113.11 "$(endpoint gateway)"
check "块 2 的身份 10.2.0.5 经七层访问内网，来源是对应的内网 IP" 100.66.0.5 "$(farm_get 10.2.0.5 "http://$INTRANET_IP:8090/" | field client)"
check "块 2 的身份 10.2.195.80（第 $FARM_PER_BLOCK 个）经四层访问内网" 100.66.195.80 "$(farm_get 10.2.195.80 "http://$INTRANET_IP:8091/" | field client)"
check "块 3 的身份 10.3.0.5 经七层访问内网，来源是对应的内网 IP" 100.67.0.5 "$(farm_get 10.3.0.5 "http://$INTRANET_IP:8090/" | field client)"
check "块 3 的身份 10.3.100.200 经四层访问内网" 100.67.100.200 "$(farm_get 10.3.100.200 "http://$INTRANET_IP:8091/" | field client)"
check "vpn-server 看到单元 2 从 gw-2 接入" 203.0.113.12 "$(endpoint gateway2)"
check "块 3 里没有登记的地址 10.3.250.1 访问内网" 无 "$(TIMEOUT=4 farm_get 10.3.250.1 "http://$INTRANET_IP:8091/" | field client)"
check "块 3 的身份访问公网站点不经过网关，来源是它所在的 Egress（egress-2）" 203.0.113.21 "$(farm_get 10.3.0.5 "http://$PUBLIC_IP:8080/" | field client)"
check "块 2 的身份访问公网站点，来源是 egress-1" 203.0.113.20 "$(farm_get 10.2.0.5 "http://$PUBLIC_IP:8080/" | field client)"
finish
