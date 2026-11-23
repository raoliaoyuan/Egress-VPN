#!/usr/bin/env bash
# 阶段 0：接入层、内核参数和压测工具。在其余阶段之前执行一次，可以重复执行。
#   - 各节点的内核参数（连接跟踪表的上限、多核收包分摊等，见 files/tune.sh）；
#   - rtr-acc：三台虚拟机和 vm-farm 的默认网关，按源地址所在的块做策略路由，下一跳是这个块的接入地址；
#   - vm-farm：把块 2、块 3 的虚拟机网段整段设成本机地址，用一个节点模拟大量虚拟机；
#   - 两台 Egress 上的 keepalived：块 1、块 2 的接入地址平时在 egress-1，块 3 的在 egress-2，互为热备；
#   - 压测工具：发流量的节点上是 labload、stream-client.py、iperf3，内网服务节点上是 labsrv 和 iperf3 服务端；
#   - vpn-server 和 rtr-core（内网核心路由器）之间的静态路由：内网服务在 rtr-core 后面，各地址块在 vpn-server 后面。
# Egress 的 Envoy 还没有配置时，两台 Egress 都不会持有接入地址（keepalived 检查 Envoy 在不在），
# 要等 20-baseline.sh 或 30-deploy-solution.sh 配好 Egress 之后虚拟机才能出去。
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/bench-lib.sh"
ADVERT=${ADVERT:-1}   # 接入地址的 VRRP 通告间隔（秒）。备用的一台在连续约 3 个间隔收不到通告后接管

boot_unit() { # 节点 boot.sh 的来源文件：装上开机脚本并立刻执行一次
	put "$1" "$FILES/tune.sh" /etc/lab/tune.sh
	put "$1" "$2" /etc/lab/boot.sh
	put "$1" "$FILES/lab-boot.service" /etc/systemd/system/lab-boot.service
	on "$1" "chmod 755 /etc/lab/tune.sh /etc/lab/boot.sh; systemctl daemon-reload; systemctl enable -q lab-boot.service; /etc/lab/boot.sh"
}

say "内核参数；VPN 服务器和内网核心路由器之间的静态路由"
printf '#!/bin/bash\n/etc/lab/tune.sh\nexit 0\n' > "$STATE/boot.tmp"
for n in intranet-svc vpn-server-2 corp-exit ctrl; do boot_unit "$n" "$STATE/boot.tmp"; done
rm -f "$STATE/boot.tmp"
boot_unit vpn-server "$FILES/vpn-server-boot.sh"
boot_unit rtr-core "$FILES/rtr-core-boot.sh"
for n in "${EGRESS_NODES[@]}" gw-1 gw-2 gw-3; do
	put "$n" "$FILES/tune.sh" /etc/lab/tune.sh
	on "$n" "chmod 755 /etc/lab/tune.sh; /etc/lab/tune.sh conntrack; echo \"$n：连接跟踪表上限 \$(cat /proc/sys/net/netfilter/nf_conntrack_max)\""
done

say "rtr-acc：按块引流"
boot_unit rtr-acc "$FILES/rtr-acc-boot.sh"
on rtr-acc "ip rule show | grep -E 'lookup 10[12]' | sed 's/^/  /'; ip route show table 101 | sed 's/^/  表 101：/'; ip route show table 102 | sed 's/^/  表 102：/'"

say "vm-farm：模拟大量虚拟机"
boot_unit vm-farm "$FILES/vm-farm-boot.sh"
install_load_client vm-farm
install_load_client vm-a

say "内网服务节点上的压测服务端"
install_load_server

say "两台 Egress：接入地址"
for eg in "${EGRESS_NODES[@]}"; do
	if [ "$eg" = egress-1 ]; then p12=150 p3=100; else p12=100 p3=150; fi
	put "$eg" "$FILES/keepalived-access.conf" /etc/keepalived/keepalived.conf.in
	put "$eg" "$FILES/tune.sh" /etc/lab/tune.sh
	put "$eg" "$FILES/egress-boot.sh" /etc/lab/boot.sh
	put "$eg" "$FILES/lab-boot.service" /etc/systemd/system/lab-boot.service
	on "$eg" ". /etc/lab/ifaces.env
chmod 755 /etc/lab/tune.sh /etc/lab/boot.sh
sed -e \"s/@ACCIF@/\$IF_ACC_NET/g\" -e \"s/@SVCIF@/\$IF_SVC_NET/g\" -e 's/@PRIO12@/$p12/; s/@PRIO3@/$p3/; s/@ADVERT@/$ADVERT/g' \
	/etc/keepalived/keepalived.conf.in > /etc/keepalived/keepalived.conf
for net in 10.1.2.0/24 10.2.0.0/16 10.3.0.0/16 10.1.253.0/24; do ip route replace \$net via 10.1.254.1 dev \$IF_ACC_NET; done
systemctl daemon-reload; systemctl enable -q keepalived.service lab-boot.service; systemctl restart keepalived.service
sleep 1; echo \"$eg：keepalived \$(systemctl is-active keepalived.service)\""
done

say "检查"
check "rtr-acc 把块 1 的流量交给块 1、块 2 的接入地址" "$ACCESS_VIP" "$(on rtr-acc ". /etc/lab/ifaces.env; ip route get 10.200.5.6 from 10.1.2.3 iif \$IF_VM_NET | grep -o 'via [0-9.]*' | cut -d' ' -f2")"
check "rtr-acc 把块 2 的流量交给同一个接入地址" "$ACCESS_VIP" "$(on rtr-acc ". /etc/lab/ifaces.env; ip route get 10.200.5.6 from 10.2.0.9 iif \$IF_FARM_NET | grep -o 'via [0-9.]*' | cut -d' ' -f2")"
check "rtr-acc 把块 3 的流量交给块 3 的接入地址" "$ACCESS_VIP3" "$(on rtr-acc ". /etc/lab/ifaces.env; ip route get 10.200.5.6 from 10.3.0.9 iif \$IF_FARM_NET | grep -o 'via [0-9.]*' | cut -d' ' -f2")"
check "虚拟机能到达它的默认网关 rtr-acc（反向路径检查没有误伤）" 通 "$(on vm-a "ping -c2 -W2 10.1.2.1 >/dev/null 2>&1 && echo 通 || echo 不通")"
check "vm-farm 能到达它的默认网关 rtr-acc" 通 "$(on vm-farm "ping -c2 -W2 10.1.253.1 >/dev/null 2>&1 && echo 通 || echo 不通")"
check "vm-farm 能绑定块 2、块 3 里的任意地址" "可以 可以" "$(on vm-farm "for a in 10.2.77.1 10.3.200.9; do python3 -c \"import socket; s = socket.socket(); s.bind(('\$a', 0)); print('可以')\" 2>/dev/null || echo 不行; done | tr '\n' ' '" | sed 's/ $//')"
check "内网服务经内网核心路由器能到 VPN 服务器" 通 "$(on intranet-svc "ping -c2 -W2 10.200.0.2 >/dev/null 2>&1 && echo 通 || echo 不通")"
check "内网服务节点上的压测服务端在监听" "7000 8090 8091" "$(on intranet-svc "ss -ltn | grep -oE ':(7000|8090|8091) ' | tr -d ': ' | sort -u | tr '\n' ' '" | sed 's/ $//')"
if on egress-1 "pgrep -x envoy >/dev/null" && on egress-2 "pgrep -x envoy >/dev/null"; then
	access_home || true
	check "块 1、块 2 的接入地址在 egress-1" egress-1 "$(access_holder "$ACCESS_VIP")"
	check "块 3 的接入地址在 egress-2" egress-2 "$(access_holder "$ACCESS_VIP3")"
else
	echo "说明：Egress 的 Envoy 还没有配置，接入地址暂时没有人持有；执行 20-baseline.sh 或 30-deploy-solution.sh 之后才有"
fi
finish
