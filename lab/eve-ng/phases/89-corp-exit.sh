#!/usr/bin/env bash
# 阶段 8.9：互联网出口和逐台阻断（先执行 87-multi-server.sh）。跑完恢复成 87 之后的样子。
#   G 对照（改之前）：非 TCP 能直接出去；虚拟机能让 Egress 替它连基础设施的地址；
#   E 出口模式“经企业出口”：去公网的连接默认经网关、隧道、VPN 服务器、内网，从企业的互联网出口（corp-exit）出去；
#     企业出口看到的来源是每台虚拟机的内网 IP；例外（按目的地、按虚拟机）仍然本地直出；
#     企业出口上的管控策略起作用；这条路不通时不放行，不会自动改成本地直出；
#   N 非 TCP 默认拒绝，只放行到指定解析器的 DNS；基础设施的地址不能作为目的地址；
#   A 审计：每条连接、每个请求留一行记录，被拒绝的也有，里面没有凭证；
#   B 逐台阻断：在 Egress、网关、VPN 服务器三处生效；多久生效、已有连接断不断、别的虚拟机受不受影响；每一处单独的效果。
# 路由上的改动（内网核心通告默认路由、隧道放行全部地址）是运行时加的，跑完撤掉，节点重启也会丢。
# 用法：89-corp-exit.sh [G E N A B 里的若干个，默认全部]
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/bench-lib.sh"
. "$(dirname "$0")/scale-lib.sh"
. "$(dirname "$0")/ms-lib.sh"
ms_on || die "还不是多台 VPN 服务器的形态，先执行 87-multi-server.sh"
SECTIONS=${*:-G E N A B}
want() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }
# 实验里承载网和“公网”原来是同一个网段，网关和公网站点直接相连。经企业出口时这不对：
# 网关会把公网站点当成直连，不走隧道。所以这里另用一个网关不直连的网段 198.51.100.0/24 当“公网”：
# 公网站点和企业出口在它上面各加一个地址，Egress 加一条直连路由（本地直出的例外要用）。
PUB_NET=198.51.100.0/24
PUB2=198.51.100.80            # 公网站点在这个网段上的地址
CORP_WAN=198.51.100.9         # 企业出口对外的地址
CORP_CORE=10.200.0.9
ALIAS_IP=198.51.100.81        # 公网站点的另一个地址，当作“按目的地本地直出”的例外（例如软件源）
DIRECT_VM=vm-c                # 按虚拟机本地直出的例外
EGRESS1_WAN=203.0.113.20
vtysh_all() { # 节点... -- vtysh 的 -c 参数...
	local nodes=() n
	while [ "$1" != -- ]; do nodes+=("$1"); shift; done; shift
	for n in "${nodes[@]}"; do on "$n" "vtysh $* >/dev/null 2>&1; vtysh -c 'clear bgp ipv4 unicast * soft' >/dev/null 2>&1; true"; done
}
# count_at <节点> <网卡变量名> <tcpdump 的过滤条件> <在哪个节点上执行> <要执行的命令>：先在第一个节点上抓包，
# 再执行命令，输出抓到几个包。抓包文件每次先删（节点上 root 不能覆盖别人的 /tmp 文件，见实验说明）。
count_at() {
	on "$1" ". /etc/lab/ifaces.env; IF_any=any; rm -f /tmp/cnt.pcap; timeout 6 tcpdump -ni \$$2 -w /tmp/cnt.pcap '$3' >/dev/null 2>&1 &"
	sleep 1
	on "$4" "$5" >/dev/null 2>&1 || true
	sleep 6
	on "$1" "tcpdump -nr /tmp/cnt.pcap 2>/dev/null | wc -l"
}
udp_send() { echo "python3 -c \"
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for _ in range(3): s.sendto(b'lab-probe', ('$1', $2))
\""; }
# 连上之后保持两秒：连接是 Egress 先接下来的，马上关掉的话它可能来不及向后面发起连接，测不出“到没到”
tcp_try() { echo "timeout 4 bash -c 'exec 3<>/dev/tcp/$1/$2; sleep 2' 2>/dev/null; true"; }
corp_log() { on corp-exit "journalctl -k --since '$1' --no-pager -o cat | grep -c 'corp-exit new .*SRC=$2 DST=$3 ' || true"; }

# ---------- 改之前的对照 ----------
if want G; then
	say "G 对照（改之前）"
	n=$(count_at public-web IF_WAN "udp and dst port 9999" vm-a "$(udp_send "$PUBLIC_IP" 9999)")
	if [ "$n" -gt 0 ]; then echo "对照成立：G 虚拟机发往公网的 UDP 直接出去了（到达公网站点 $n 个）"; else echo "失败：G 对照组没有抓到包"; FAILS=$((FAILS + 1)); fi
	n=$(count_at egress-2 IF_ACC_NET "tcp dst port 22 and src host 10.1.254.20" vm-a "$(tcp_try 10.1.254.21 22)")
	if [ "$n" -gt 0 ]; then echo "对照成立：G 虚拟机让 Egress 替它去连接入网段上的另一台 Egress 的 SSH 端口（到达 $n 个包）"; else echo "失败：G 对照组没有抓到包"; FAILS=$((FAILS + 1)); fi
fi

# ---------- 部署 ----------
restore() {
	say "恢复：撤掉企业出口的路由、收紧的规则和阻断"
	local gw srv s n
	for n in "${EGRESS_NODES[@]}"; do on "$n" "nft flush set ip egress blocked 2>/dev/null; true" || true; done
	for srv in "${MS_SERVERS[@]}"; do on "$srv" "nft delete table ip vpndeny 2>/dev/null; true" || true; done
	egress_files >/dev/null 2>&1 || true
	egress_config solution >/dev/null || true
	vtysh_all rtr-core -- -c "'conf t'" -c "'router bgp $CORE_AS'" -c "'address-family ipv4 unicast'" -c "'no network 0.0.0.0/0'" || true
	vtysh_all "${ALL_GATEWAYS[@]}" "${MS_SERVERS[@]}" rtr-core -- -c "'conf t'" -c "'no ip prefix-list INTRANET seq 20'" || true
	on rtr-core "ip route del default 2>/dev/null; true" || true
	for gw in "${ALL_GATEWAYS[@]}"; do
		n=${GW_NUM[$gw]}
		for srv in "${MS_SERVERS[@]}"; do
			s=${SRV_NUM[$srv]}
			on "$gw" "wg set wg-s$s peer $(wgpub "${SRV_KEY[$srv]}") allowed-ips $(link_srv "$s" "$n")/32,10.200.0.0/16" || true
		done
	done
	on corp-exit "nft delete table ip corpexit 2>/dev/null; true" || true
	on public-web ". /etc/lab/ifaces.env; ip addr del $ALIAS_IP/24 dev \$IF_WAN 2>/dev/null; ip addr del $PUB2/24 dev \$IF_WAN 2>/dev/null; true" || true
	on corp-exit ". /etc/lab/ifaces.env; ip addr del $CORP_WAN/24 dev \$IF_WAN 2>/dev/null; true" || true
	for n in "${EGRESS_NODES[@]}"; do on "$n" "ip route del $PUB_NET 2>/dev/null; true" || true; done
	push_mappings >/dev/null || true
}
[ -z "${KEEP:-}" ] || restore() { echo "KEEP=1：没有恢复"; }

want E || want N || want A || want B || finish
trap restore EXIT

say "部署：企业出口"
on public-web ". /etc/lab/ifaces.env; ip addr replace $PUB2/24 dev \$IF_WAN; ip addr replace $ALIAS_IP/24 dev \$IF_WAN"
for eg in "${EGRESS_NODES[@]}"; do on "$eg" ". /etc/lab/ifaces.env; ip route replace $PUB_NET dev \$IF_WAN"; done
# corp-exit：对虚拟机的内网 IP 做地址转换后发往公网，新连接记日志；一条管控策略（禁止访问公网站点的 8081 端口）
on corp-exit ". /etc/lab/ifaces.env
/etc/lab/tune.sh conntrack
sysctl -qw net.ipv4.ip_forward=1
ip addr replace $CORP_WAN/24 dev \$IF_WAN
ip route replace 100.64.0.0/10 via $CORE_IP dev \$IF_CORE_NET
nft -f - <<NFT
table ip corpexit
delete table ip corpexit
table ip corpexit {
	chain forwarding {
		type filter hook forward priority filter; policy drop;
		ct state established,related accept
		iifname \"\$IF_CORE_NET\" oifname \"\$IF_WAN\" ip daddr $PUB2 tcp dport 8081 log prefix \"corp-exit deny \" reject with tcp reset
		iifname \"\$IF_CORE_NET\" oifname \"\$IF_WAN\" ct state new log prefix \"corp-exit new \" accept
	}
	chain nat {
		type nat hook postrouting priority srcnat; policy accept;
		oifname \"\$IF_WAN\" masquerade
	}
}
NFT"
# 内网核心：默认路由指向企业出口，并通告给 VPN 服务器；服务器、网关放行这条默认路由
on rtr-core ". /etc/lab/ifaces.env; ip route replace default via $CORP_CORE dev \$IF_CORE_NET"
vtysh_all "${ALL_GATEWAYS[@]}" "${MS_SERVERS[@]}" rtr-core -- -c "'conf t'" -c "'ip prefix-list INTRANET seq 20 permit 0.0.0.0/0'"
vtysh_all rtr-core -- -c "'conf t'" -c "'router bgp $CORE_AS'" -c "'address-family ipv4 unicast'" -c "'network 0.0.0.0/0'"
# 网关一侧的隧道放行全部目的地址（服务器一侧不变：从隧道进来的包，源地址仍然只能是登记过的地址块）
for gw in "${ALL_GATEWAYS[@]}"; do
	n=${GW_NUM[$gw]}
	for srv in "${MS_SERVERS[@]}"; do
		s=${SRV_NUM[$srv]}
		on "$gw" "wg set wg-s$s peer $(wgpub "${SRV_KEY[$srv]}") allowed-ips 0.0.0.0/0"
	done
done
for _ in $(seq 1 30); do [ "$(nexthops gw-1 default) $(nexthops gw-2 default)" = "2 2" ] && break; sleep 1; done
check "网关上的默认路由经两条隧道（从 BGP 学来）" "2 2 2" "$(nexthops gw-1 default) $(nexthops gw-2 default) $(nexthops gw-3 default)"
# VPN 服务器上的拒绝名单（逐台阻断的第三处）。平时是空的
for srv in "${MS_SERVERS[@]}"; do
	on "$srv" "nft -f - <<NFT
table ip vpndeny
delete table ip vpndeny
table ip vpndeny {
	set denied {
		type ipv4_addr
	}
	chain forwarding {
		type filter hook forward priority -10; policy accept;
		ip saddr @denied counter drop
		ip daddr @denied counter drop
	}
}
NFT"
done
if want G || want N; then
	# 这一条对照要在“默认路由已经经隧道、Egress 的规则还没有收紧”的时候做
	n=$(count_at vpn-server any "tcp dst port 179 and dst host ${SRV_CORE[vpn-server]} and src net 100.64.0.0/22" vm-a "$(tcp_try "${SRV_CORE[vpn-server]}" 179)")
	if [ "$n" -gt 0 ]; then echo "对照成立：互联网流量改走隧道之后、收紧之前，虚拟机能经隧道连到 VPN 服务器在内网一侧的地址（BGP 端口，到达 $n 个包）"
	else echo "说明：收紧之前，虚拟机经隧道去连 VPN 服务器在内网一侧的地址没有到达（0 个包）"; fi
fi
say "两台 Egress：出口模式改成经企业出口（例外：目的地 $ALIAS_IP、虚拟机 $DIRECT_VM），打开审计，换成收紧的内核规则"
for eg in "${EGRESS_NODES[@]}"; do
	put "$eg" "$FILES/egress-strict.nft" /etc/lab/egress.nft.in
	on "$eg" '. /etc/lab/ifaces.env
sed -e "s/@VMIF@/$IF_ACC_NET/g" -e "s/@WANIF@/$IF_WAN/g" /etc/lab/egress.nft.in > /etc/lab/egress.nft
nft -f /etc/lab/egress.nft; rm -f /var/log/egress-audit.log'
done
egress_config solution "${VMS[*]}" "--corp-exit --audit --direct-dst $ALIAS_IP/32 --direct-src ${REAL_IP[$DIRECT_VM]}/32"
T0=$(on corp-exit "date '+%Y-%m-%d %H:%M:%S'")
sleep 2

if want E; then
	say "E 经企业出口"
	check "E vm-a 访问公网站点：对端看到的来源是企业出口的地址" "$CORP_WAN" "$(get vm-a "http://$PUB2:8080/" | field client)"
	check "E 企业出口看到的来源是 vm-a 的内网 IP（它的日志里有这条新连接）" 有 "$([ "$(corp_log "$T0" "${INTRA_IP[vm-a]}" "$PUB2")" -gt 0 ] && echo 有 || echo 无)"
	check "E 块 2 的身份 10.2.0.5 访问公网站点：来源是企业出口的地址" "$CORP_WAN" "$(farm_get 10.2.0.5 "http://$PUB2:8080/" | field client)"
	check "E 块 3 的身份 10.3.0.5（另一个网关单元）：同上" "$CORP_WAN" "$(farm_get 10.3.0.5 "http://$PUB2:8080/" | field client)"
	check "E 企业出口看到的这两个来源分别是它们的内网 IP" "有 有" "$([ "$(corp_log "$T0" 100.66.0.5 "$PUB2")" -gt 0 ] && echo 有 || echo 无) $([ "$(corp_log "$T0" 100.67.0.5 "$PUB2")" -gt 0 ] && echo 有 || echo 无)"
	check "E 例外（按目的地）：vm-a 访问 $ALIAS_IP，从 Egress 本地直出" "$EGRESS1_WAN" "$(get vm-a "http://$ALIAS_IP:8080/" | field client)"
	check "E 例外（按虚拟机）：$DIRECT_VM 访问公网站点，从 Egress 本地直出" "$EGRESS1_WAN" "$(get "$DIRECT_VM" "http://$PUB2:8080/" | field client)"
	r=$(get "$DIRECT_VM" "http://$INTRANET_IP/")
	check "E $DIRECT_VM 访问内网不受例外影响" "${INTRA_IP[$DIRECT_VM]} $DIRECT_VM" "$(echo "$r" | field client) $(echo "$r" | field identity)"
	check "E vm-a 访问内网照常" "${INTRA_IP[vm-a]}" "$(get vm-a "http://$INTRANET_IP:8080/" | field client)"
	c=$(code vm-a "http://$PUB2:8081/")
	check "E 企业出口上的管控策略起作用：vm-a 访问被禁止的端口不成功" 不成功 "$([ "$c" = 200 ] && echo 成功 || echo 不成功)"
	check "E 走例外的 $DIRECT_VM 不经过企业的管控，访问同一个端口成功" 200 "$(code "$DIRECT_VM" "http://$PUB2:8081/")"
	run_load "corp/经企业出口/块2" vm-farm 20 "vm-farm egress-1 gw-1 vpn-server vpn-server-2 rtr-core corp-exit" --target "$PUB2:8080" --src-base 10.2.0.1 --src-count 800 --conns 16 --threads 2 --rate 40 --timeout 5000 || true
	# 公网站点上的回显服务是 Python 写的，很慢，所以这里只是低速地让许多身份各走一遍，不是压测
	check "E 块 2 的 800 个身份逐个经企业出口访问公网站点：失败数" 0 "$(fj "$LAST_LOAD" .errors)"

	say "E（续）企业出口这条路不通：不放行，也不改成本地直出"
	on corp-exit "sysctl -qw net.ipv4.ip_forward=0"
	n=$(count_at public-web IF_WAN "tcp dst port 8080 and (src host $EGRESS1_WAN or src host 203.0.113.21)" vm-a "curl -s -m 4 -o /dev/null http://$PUB2:8080/")
	check "E 企业出口不转发时，vm-a 访问公网站点不成功" 不成功 "$([ "$(TIMEOUT=4 get vm-a "http://$PUB2:8080/" | field client)" = "$CORP_WAN" ] && echo 成功 || echo 不成功)"
	check "E 这期间从 Egress 的出口地址直接到达公网站点的包" 0 "$n"
	check "E 这期间访问内网不受影响" "${INTRA_IP[vm-a]}" "$(get vm-a "http://$INTRANET_IP:8080/" | field client)"
	on corp-exit "sysctl -qw net.ipv4.ip_forward=1"
	sleep 2
	check "E 企业出口恢复后又通了" "$CORP_WAN" "$(get vm-a "http://$PUB2:8080/" | field client)"
fi

if want N; then
	say "N 非 TCP 默认拒绝；基础设施的地址不能作为目的地址"
	check "N vm-a 发往公网站点的 UDP（9999 端口）到达的个数" 0 "$(count_at public-web IF_WAN "udp and dst port 9999" vm-a "$(udp_send "$PUBLIC_IP" 9999)")"
	check "N 发往 443 端口的 UDP（QUIC 用的）到达的个数" 0 "$(count_at public-web IF_WAN "udp and dst port 443" vm-a "$(udp_send "$PUBLIC_IP" 443)")"
	check "N vm-a ping 公网站点" 不通 "$(on vm-a "ping -c2 -W2 $PUBLIC_IP >/dev/null 2>&1 && echo 通 || echo 不通")"
	n=$(count_at public-web IF_WAN "udp and dst port 53 and dst host $PUBLIC_IP" vm-a "$(udp_send "$PUBLIC_IP" 53)")
	check "N 发往指定解析器的 DNS 到达了" 到达 "$([ "$n" -gt 0 ] && echo 到达 || echo 没到)"
	check "N 发往别的地址的 DNS 到达的个数" 0 "$(count_at public-web IF_WAN "udp and dst port 53 and dst host $ALIAS_IP" vm-a "$(udp_send "$ALIAS_IP" 53)")"
	check "N 已迁移的 vm-a 向 VPN 服务器的隧道端口发 UDP，到达的个数" 0 "$(count_at vpn-server IF_WAN "udp and dst port 51820 and src host $EGRESS1_WAN" vm-a "$(udp_send 203.0.113.1 51820)")"
	check "N vm-a 让 Egress 去连接入网段上另一台 Egress 的 SSH 端口，到达的包" 0 "$(count_at egress-2 IF_ACC_NET "tcp dst port 22 and src host 10.1.254.20" vm-a "$(tcp_try 10.1.254.21 22)")"
	check "N vm-a 经隧道去连 VPN 服务器在内网一侧的地址，到达的包" 0 "$(count_at vpn-server any "tcp dst port 179 and dst host ${SRV_CORE[vpn-server]} and src net 100.64.0.0/22" vm-a "$(tcp_try "${SRV_CORE[vpn-server]}" 179)")"
	check "N vm-a 去连网关在承载网上的地址，到达的包" 0 "$(count_at gw-1 IF_WAN "tcp dst port 22 and dst host 203.0.113.11" vm-a "$(tcp_try 203.0.113.11 22)")"
	check "N 收紧之后 vm-a 访问内网和公网照常" "${INTRA_IP[vm-a]} $CORP_WAN" "$(get vm-a "http://$INTRANET_IP:8080/" | field client) $(get vm-a "http://$PUB2:8080/" | field client)"
	check "N Egress 的内核日志里有被拒绝的非 TCP 的记录" 有 "$([ "$(on egress-1 "journalctl -k --since -3min --no-pager -o cat | grep -c 'egress-deny ' || true")" -gt 0 ] && echo 有 || echo 无)"
fi

if want A; then
	say "A 审计"
	get vm-a "http://$INTRANET_IP/" >/dev/null; get vm-a "http://$PUB2:8080/" >/dev/null; get vm-a "http://$ALIAS_IP:8080/" >/dev/null
	code vm-a "http://$PUBLIC_IP/" "-H 'Host: intranet-svc'" >/dev/null
	sleep 13   # Envoy 的访问日志默认每 10 秒落盘一次
	q() { on egress-1 "jq -c 'select($1)' /var/log/egress-audit.log 2>/dev/null | wc -l"; }
	check "A 访问内网服务的请求有记录（哪台虚拟机、去哪里、走哪个上游、结果）" 有 "$([ "$(q '.vm == "10.1.2.3" and .dst == "10.200.5.6:80" and .via == "vpn_gateway_1" and .code == 200')" -gt 0 ] && echo 有 || echo 无)"
	check "A 经企业出口访问公网的连接有记录" 有 "$([ "$(q '.vm == "10.1.2.3" and .dst == "198.51.100.80:8080" and .via == "vpn_gateway_1" and .flags == "-"')" -gt 0 ] && echo 有 || echo 无)"
	check "A 本地直出的连接有记录，并且记下了用的出口地址" 有 "$([ "$(q '.vm == "10.1.2.3" and .dst == "198.51.100.81:8080" and .via == "direct" and (.egress_src | startswith("203.0.113.20:"))')" -gt 0 ] && echo 有 || echo 无)"
	check "A 被拒绝的请求也有记录（Host 对不上的那个，404）" 有 "$([ "$(q '.vm == "10.1.2.3" and .code == 404')" -gt 0 ] && echo 有 || echo 无)"
	check "A 审计日志里出现的凭证个数" 0 "$(on egress-1 "grep -oE '$TOKEN_RE' /var/log/egress-audit.log | sort -u | wc -l")"
	echo "  egress-1 的审计日志共 $(on egress-1 "wc -l < /var/log/egress-audit.log") 行，例如：$(on egress-1 "jq -c 'select(.dst == \"198.51.100.80:8080\")' /var/log/egress-audit.log | tail -1")"
fi

# ---------- 逐台阻断 ----------
# block <虚拟机> <egress|gateway|server|all>：在指定的位置阻断这台虚拟机。unblock 是反过来的操作，内网 IP 不变。
block() {
	local vm=$1 where=$2 n real=${REAL_IP[$1]} intra=${INTRA_IP[$1]}
	if [ "$where" = egress ] || [ "$where" = all ]; then
		# 拒绝它的新连接；杀掉 Envoy 上和它之间已有的连接（对端也随之关闭）
		for n in "${EGRESS_NODES[@]}"; do on "$n" "nft add element ip egress blocked { $real }; ss -K dst $real >/dev/null 2>&1; true"; done
	fi
	if [ "$where" = gateway ] || [ "$where" = all ]; then
		# 删掉它的映射，清掉连接跟踪记录，杀掉以它的地址发起的上游连接
		for n in "${ALL_GATEWAYS[@]}"; do on "$n" "nft delete element ip vpngw vm2intra { $real } 2>/dev/null; conntrack -D -s $real >/dev/null 2>&1; ss -K src $real >/dev/null 2>&1; true"; done
	fi
	if [ "$where" = server ] || [ "$where" = all ]; then
		for n in "${MS_SERVERS[@]}"; do on "$n" "nft add element ip vpndeny denied { $intra }"; done
	fi
}
unblock() {
	local vm=$1 n real=${REAL_IP[$1]} intra=${INTRA_IP[$1]}
	for n in "${EGRESS_NODES[@]}"; do on "$n" "nft delete element ip egress blocked { $real } 2>/dev/null; true"; done
	for n in "${MS_SERVERS[@]}"; do on "$n" "nft delete element ip vpndeny denied { $intra } 2>/dev/null; true"; done
	for n in "${ALL_GATEWAYS[@]}"; do on "$n" "nft add element ip vpngw vm2intra { $real : $intra } 2>/dev/null; true"; done
}
intra_ok() { [ "$(TIMEOUT=3 get "$1" "http://$INTRANET_IP:8080/" | field client)" = "${INTRA_IP[$1]}" ] && echo 通 || echo 不通; }
inet_ok() { [ "$(TIMEOUT=3 get "$1" "http://$PUB2:8080/" | field client)" = "$CORP_WAN" ] && echo 通 || echo 不通; }
direct_ok() { [ "$(TIMEOUT=3 get "$1" "http://$ALIAS_IP:8080/" | field client)" = "$EGRESS1_WAN" ] && echo 通 || echo 不通; }

if want B; then
	say "B 逐台阻断：三处一起（阻断 vm-a）"
	check "B 阻断之前 vm-a：内网、经企业出口的公网、本地直出的例外" "通 通 通" "$(intra_ok vm-a) $(inet_ok vm-a) $(direct_ok vm-a)"
	stream_bg vm-a blk --target "$INTRANET_IP:$ECHO_PORT" --count 20 --duration 25
	stream_bg vm-farm oth --target "$INTRANET_IP:$ECHO_PORT" --src-base 10.2.1.1 --count 40 --duration 25
	sleep 6
	t0=$(date +%s.%N); t0vm=$(on vm-a "date +%s.%N")   # 后一个是 vm-a 自己的钟，算它的长连接什么时候断用
	block vm-a all
	t1=$(date +%s.%N)
	echo "  从发出到三处都执行完：$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }') 秒（操作机经 SSH 逐台执行，七个节点）"
	check "B 阻断之后 vm-a：内网、经企业出口的公网、本地直出的例外" "不通 不通 不通" "$(intra_ok vm-a) $(inet_ok vm-a) $(direct_ok vm-a)"
	r=$(get vm-b "http://$INTRANET_IP/")
	check "B 别的虚拟机不受影响：vm-b 的来源和凭证" "${INTRA_IP[vm-b]} vm-b" "$(echo "$r" | field client) $(echo "$r" | field identity)"
	check "B vm-b 的公网访问也照常" 通 "$(inet_ok vm-b)"
	sleep 16
	on vm-a "cat /tmp/stream-blk.json" > "$RESULTS/stream-blk.json" 2>/dev/null || true
	on vm-farm "cat /tmp/stream-oth.json" > "$RESULTS/stream-oth.json" 2>/dev/null || true
	b=$(jq -c 'del(.detail)' "$RESULTS/stream-blk.json" 2>/dev/null || echo '{}'); o=$(jq -c 'del(.detail)' "$RESULTS/stream-oth.json" 2>/dev/null || echo '{}')
	record "block/三处一起/被阻断的长连接" "$b"; record "block/三处一起/别的长连接" "$o"
	check "B vm-a 已有的 20 条长连接全部断了" 20 "$(fj "$b" .broken)"
	check "B 块 2 的 40 条长连接一条没断" 0 "$(fj "$o" .broken)"
	echo "  vm-a 的长连接是在阻断发出后多久断的：$(jq -r --argjson t "$t0vm" '[.detail[] | select(.broken != null) | (.broken_at // .last_echo // 0) - $t] | if length > 0 then "最早 \(min | . * 10 | round / 10) 秒，最晚 \(max | . * 10 | round / 10) 秒" else "没有记录" end' "$RESULTS/stream-blk.json" 2>/dev/null || echo 没有记录)"
	unblock vm-a
	sleep 1
	r=$(get vm-a "http://$INTRANET_IP/")
	check "B 恢复之后 vm-a 照常，内网 IP 不变" "${INTRA_IP[vm-a]} vm-a 通" "$(echo "$r" | field client) $(echo "$r" | field identity) $(inet_ok vm-a)"

	say "B 每一处单独的效果"
	block vm-a server
	check "B 只在 VPN 服务器上拒绝：内网不通、经企业出口的公网不通；本地直出的例外不经过它，仍然通" "不通 不通 通" "$(intra_ok vm-a) $(inet_ok vm-a) $(direct_ok vm-a)"
	check "B 这时 vm-b 照常" 通 "$(intra_ok vm-b)"
	unblock vm-a; sleep 1
	block vm-a gateway
	check "B 只在网关上删掉映射：内网不通、经企业出口的公网不通；本地直出的例外仍然通" "不通 不通 通" "$(intra_ok vm-a) $(inet_ok vm-a) $(direct_ok vm-a)"
	unblock vm-a; sleep 1
	block vm-a egress
	check "B 只在 Egress 上拒绝：三样都不通" "不通 不通 不通" "$(intra_ok vm-a) $(inet_ok vm-a) $(direct_ok vm-a)"
	unblock vm-a; sleep 1
	check "B 全部恢复之后 vm-a 三样都通" "通 通 通" "$(intra_ok vm-a) $(inet_ok vm-a) $(direct_ok vm-a)"
fi

trap - EXIT
restore
sleep 3
wait_bgp || true
say "收尾检查"
for vm in "${VMS[@]}"; do
	r=$(get "$vm" "http://$INTRANET_IP/")
	check "$vm 的来源和凭证" "${INTRA_IP[$vm]} $vm" "$(echo "$r" | field client) $(echo "$r" | field identity)"
done
check "访问公网恢复成本地直出" "$EGRESS1_WAN" "$(get vm-a "http://$PUBLIC_IP:8080/" | field client)"
check "网关上不再有默认路由" "0 0" "$(nexthops gw-1 default) $(nexthops gw-2 default)"
finish
