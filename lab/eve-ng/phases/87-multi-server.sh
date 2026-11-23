#!/usr/bin/env bash
# 阶段 8.7：多台 VPN 服务器同时工作（先执行 80-scale-a.sh；块 3 走数据面 A）。可以重复执行。
# 在数据面 A 的规模化形态上改成设计里的“目标做法”：
#   - 两台 VPN 服务器（vpn-server、vpn-server-2）同时工作，后面是内网核心路由器 rtr-core；
#   - 每台网关自己一对密钥，到每台服务器各一条隧道（六条），一直建着；
#   - 每条隧道里一个 BGP 会话加 BFD：网关通告它此刻承载的单元的地址块，服务器通告内网网段；
#     服务器和内网核心之间同样是 BGP 加 BFD。每个方向都是两条等价路由；
#   - 谁承载哪个单元仍由 keepalived 决定；热备接管不再启动隧道、等握手，只是开始通告这个单元的块；
#   - vpn-server 上原来的 wg0 只留给旧方式（虚拟机自带隧道）的 /32 对端，可以并存。
# Egress 不用改。回到规模化形态：先执行 30-deploy-solution.sh，再执行 80-scale-a.sh。
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/bench-lib.sh"
. "$(dirname "$0")/scale-lib.sh"
. "$(dirname "$0")/ms-lib.sh"
GW_ADVERT=${GW_ADVERT:-1}
scale_on || die "还不是规模化形态，先执行 80-scale-a.sh"
b_on && die "块 3 现在走数据面 B；先执行 30-deploy-solution.sh 和 80-scale-a.sh"

say "路由软件（FRR：bgpd、bfdd）"
for n in "${ALL_GATEWAYS[@]}" "${MS_SERVERS[@]}" rtr-core; do apt_install "$n" frr; done
gen_wg_keys gwb-1 gwb-2 gwb-3 server2
touch "$STATE/ms-on"

say "三台网关：先停掉 keepalived 和按单元的隧道"
for gw in "${ALL_GATEWAYS[@]}"; do on "$gw" "systemctl stop keepalived.service 2>/dev/null; true"; done

say "vpn-server：原来的 wg0 只留给旧方式的虚拟机"
on vpn-server "systemctl stop wg-quick@wg0 2>/dev/null; for b in $BLOCK2_INTRA $BLOCK3_INTRA; do ip route del \$b 2>/dev/null; done; true"
apply_server_conf

say "两台 VPN 服务器：每台网关一个隧道接口，BGP 加 BFD"
for srv in "${MS_SERVERS[@]}"; do deploy_ms_server "$srv"; done
say "内网核心路由器"
deploy_ms_core

say "三台网关：到每台服务器一条隧道，BGP 加 BFD，通告由 keepalived 控制"
deploy_ms_gateway gw-1 150 100 "$GW_ADVERT"
deploy_ms_gateway gw-2 100 150 "$GW_ADVERT"
deploy_ms_gateway gw-3 120 120 "$GW_ADVERT"
push_mappings
for _ in $(seq 1 60); do
	[ "$(nexthops gw-1 "$INTRANET_NET") $(nexthops gw-2 "$INTRANET_NET") $(nexthops gw-3 "$INTRANET_NET")" = "2 2 2" ] && break
	sleep 2
done
echo "三台网关去内网的下一跳个数：$(nexthops gw-1 "$INTRANET_NET") $(nexthops gw-2 "$INTRANET_NET") $(nexthops gw-3 "$INTRANET_NET")"
# 启动顺序决定谁当主用（都配成了不抢占），做法和 80-scale-a.sh 相同
on gw-1 "systemctl restart keepalived.service"
for _ in $(seq 1 20); do [ "$(unit_holder "$GATEWAY_VIP2")" = gw-1 ] && break; sleep 1; done
on gw-2 "systemctl restart keepalived.service"
on gw-3 "systemctl restart keepalived.service"
sleep $((GW_ADVERT * 4 + 2))
unit_release gw-1 U2
wait_bgp || echo "等了两分钟，会话或路由还没有到齐"
echo "单元 1 在 $(unit_holder "$GATEWAY_VIP")，单元 2 在 $(unit_holder "$GATEWAY_VIP2")"

say "检查"
sleep 2
check "单元 1 的服务地址在 gw-1、单元 2 的在 gw-2" "gw-1 gw-2" "$(unit_holders "$GATEWAY_VIP") $(unit_holders "$GATEWAY_VIP2")"
check "gw-1 通告的是单元 1 的两个块" "$GATEWAY_BLOCK $BLOCK2_INTRA" "$(advertised gw-1)"
check "gw-2 通告的是单元 2 的块" "$BLOCK3_INTRA" "$(advertised gw-2)"
check "共享热备 gw-3 什么都不通告" "" "$(advertised gw-3)"
for gw in "${ALL_GATEWAYS[@]}"; do
	check "$gw：两条隧道都在，BGP 会话 2 个、BFD 会话 2 个都正常，去内网有 2 个下一跳" "2 2 2 2" \
		"$(on "$gw" "ip -br link | grep -c '^wg-s'") $(bgp_up "$gw") $(bfd_up "$gw") $(nexthops "$gw" "$INTRANET_NET")"
done
for srv in "${MS_SERVERS[@]}"; do
	check "$srv：BGP 会话 4 个（三台网关加内网核心）、BFD 会话 4 个都正常" "4 4" "$(bgp_up "$srv") $(bfd_up "$srv")"
done
check "内网核心上每个块有 2 个下一跳（两台服务器）" "2 2 2" "$(nexthops rtr-core "$GATEWAY_BLOCK") $(nexthops rtr-core "$BLOCK2_INTRA") $(nexthops rtr-core "$BLOCK3_INTRA")"
check "vpn-server 上块 3 的路由指向 gw-2 的隧道接口" wg-g2 "$(on vpn-server "ip -4 route show $BLOCK3_INTRA | grep -o 'dev [a-z0-9-]*' | cut -d' ' -f2")"
check "vpn-server-2 上块 2 的路由指向 gw-1 的隧道接口" wg-g1 "$(on vpn-server-2 "ip -4 route show $BLOCK2_INTRA | grep -o 'dev [a-z0-9-]*' | cut -d' ' -f2")"
for vm in "${VMS[@]}"; do
	r=$(get "$vm" "http://$INTRANET_IP/")
	check "$vm（块 1）访问内网的来源不变、凭证照常注入" "${INTRA_IP[$vm]} $vm" "$(echo "$r" | field client) $(echo "$r" | field identity)"
done
check "块 2 的身份 10.2.0.5 经七层访问内网" 100.66.0.5 "$(farm_get 10.2.0.5 "http://$INTRANET_IP:8090/" | field client)"
check "块 3 的身份 10.3.0.5 经七层访问内网" 100.67.0.5 "$(farm_get 10.3.0.5 "http://$INTRANET_IP:8090/" | field client)"
check "块 3 的身份 10.3.100.200 经四层访问内网" 100.67.100.200 "$(farm_get 10.3.100.200 "http://$INTRANET_IP:8091/" | field client)"
check "块 3 里没有登记的地址 10.3.250.1 访问内网" 无 "$(TIMEOUT=4 farm_get 10.3.250.1 "http://$INTRANET_IP:8091/" | field client)"
check "访问公网不受影响" 203.0.113.21 "$(farm_get 10.3.0.5 "http://$PUBLIC_IP:8080/" | field client)"
finish
