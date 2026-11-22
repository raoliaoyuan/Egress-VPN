#!/usr/bin/env bash
# 阶段 8.5：块 3 改走数据面 B。开始前要已经是规模化形态（80-scale-a.sh）。可以重复执行。
# 块 1、块 2 仍然走数据面 A，两种数据面同时在跑。
#   - 两台 Egress：加载数据面 B 的内核规则（地址映射、连接跟踪分区、标记、策略路由），
#     Envoy 多两个监听器，去内网的路由指向三台网关；
#   - 三台网关：各自多一条自己的隧道（wgb），打开转发，对块 3 只转发、不跟踪；
#   - vpn-server：每台网关一个隧道接口，块 3 的回程在三条隧道之间分摊；块 3 不再属于网关单元 2。
# 把块 3 改回数据面 A：再执行一次 80-scale-a.sh 之前先执行 30-deploy-solution.sh（它会撤掉数据面 B 的东西）。
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/scale-lib.sh"

scale_on || die "还不是规模化形态，先执行 80-scale-a.sh"
gen_wg_keys gwb-1 gwb-2 gwb-3
touch "$STATE/b-on"

say "三台网关：自己的隧道、转发规则、回程路由"
macs=$(for eg in "${EGRESS_NODES[@]}"; do on "$eg" '. /etc/lab/ifaces.env; cat /sys/class/net/$IF_SVC_NET/address'; done | paste -sd, -)
for gw in "${ALL_GATEWAYS[@]}"; do deploy_b_gateway "$gw" "$macs"; done

say "vpn-server：每台网关一个隧道接口，块 3 的回程走多条等价路由"
deploy_b_server

say "两台 Egress：数据面 B 的内核规则、去内网的多条等价路由"
for eg in "${EGRESS_NODES[@]}"; do deploy_b_egress "$eg"; done
egress_config solution
# vpn-server 上的隧道接口重建之后，要等网关那一头下一次发包才会重新握手（网关配了 25 秒的保活），
# 探测脚本在那之后才把这台网关放回路由。这里等三台都回来再检查。
for _ in $(seq 1 45); do
	[ "$(on vpn-server "ip route show $B_BLOCK_INTRA | grep -c nexthop")" = 3 ] && break
	sleep 1
done

say "检查"
check "三台网关各自的隧道都握手成功" "3" "$(for gw in "${ALL_GATEWAYS[@]}"; do on "$gw" "wg show wgb latest-handshakes | awk '\$2 > 0' | wc -l"; done | grep -c '^1$')"
check "egress-2 上去内网的路由有三个下一跳" 3 "$(on egress-2 "ip route show 10.200.0.0/16 | grep -c 'nexthop'")"
check "egress-1（块 3 的备用）上同样有" 3 "$(on egress-1 "ip route show 10.200.0.0/16 | grep -c 'nexthop'")"
check "vpn-server 上块 3 的回程有三个下一跳" 3 "$(on vpn-server "ip route show $B_BLOCK_INTRA | grep -c 'nexthop'")"
check "vpn-server 上块 3 不再属于任何网关单元的对端" 0 "$(on vpn-server "wg show wg0 allowed-ips | grep -c '$B_BLOCK_INTRA' || true")"
check "块 3 的身份 10.3.0.5 经七层访问内网，来源是对应的内网 IP" 100.67.0.5 "$(farm_get 10.3.0.5 "http://$INTRANET_IP:8090/" | field client)"
check "块 3 的身份 10.3.100.200 经四层访问内网" 100.67.100.200 "$(farm_get 10.3.100.200 "http://$INTRANET_IP:8091/" | field client)"
check "块 3 的身份访问回显服务的 80 端口（七层）" 100.67.0.5 "$(farm_get 10.3.0.5 "http://$INTRANET_IP/" | field client)"
check "块 3 里没有登记的地址 10.3.250.1 访问内网" 无 "$(TIMEOUT=4 farm_get 10.3.250.1 "http://$INTRANET_IP:8091/" | field client)"
check "块 3 的身份访问公网站点，来源是 egress-2" 203.0.113.21 "$(farm_get 10.3.0.5 "http://$PUBLIC_IP:8080/" | field client)"
check "块 2 仍走数据面 A，来源不变" 100.66.0.5 "$(farm_get 10.2.0.5 "http://$INTRANET_IP:8090/" | field client)"
for vm in "${VMS[@]}"; do
	r=$(get "$vm" "http://$INTRANET_IP/")
	check "$vm（块 1，数据面 A）来源不变、凭证照常注入" "${INTRA_IP[$vm]} $vm" "$(echo "$r" | field client) $(echo "$r" | field identity)"
done
# 网关上没有块 3 的连接状态：发 20 个请求，三台网关的连接跟踪表里都找不到块 3 的记录，而 wgb 上有包经过。
# 先清掉块 3 还走数据面 A 时留在网关上的记录（刚关闭的连接会留 30 秒）
for gw in "${ALL_GATEWAYS[@]}"; do on "$gw" "conntrack -D -s $B_BLOCK_REAL >/dev/null 2>&1; true"; done
before=$(for gw in "${ALL_GATEWAYS[@]}"; do on "$gw" "cat /sys/class/net/wgb/statistics/tx_packets"; done | awk '{ s += $1 } END { print s + 0 }')
on vm-farm "for i in \$(seq 1 20); do curl -s -m 3 -o /dev/null --interface 10.3.0.\$((i + 10)) http://$INTRANET_IP:8091/; done"
after=$(for gw in "${ALL_GATEWAYS[@]}"; do on "$gw" "cat /sys/class/net/wgb/statistics/tx_packets"; done | awk '{ s += $1 } END { print s + 0 }')
check "三台网关的连接跟踪表里块 3 的记录数" 0 "$(for gw in "${ALL_GATEWAYS[@]}"; do on "$gw" "conntrack -L 2>/dev/null | grep -c -e 'src=100\.67\.' -e 'src=10\.3\.' || true"; done | awk '{ s += $1 } END { print s + 0 }')"
if [ $((after - before)) -gt 0 ]; then echo "通过：这 20 个请求经三台网关的 wgb 隧道转发出去（$((after - before)) 个包）"; else echo "失败：wgb 隧道上没有包"; FAILS=$((FAILS + 1)); fi
finish
