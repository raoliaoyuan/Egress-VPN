#!/usr/bin/env bash
# 阶段 5：逐项验证。开始前的状态：vm-a 已迁移，vm-b、vm-c 仍用旧方式。
# 结束时的状态：vm-a、vm-c 走新方案，vm-b 仍用旧方式（由 60-ha.sh 之前的步骤再迁移）。
set -euo pipefail
. "$(dirname "$0")/common.sh"
CRED=$(credential)

say "准备：把三台虚拟机置于约定的起始状态（vm-a 已迁移，vm-b、vm-c 用旧方式）"
grep -qw vm-a "$STATE/legacy" && "$(dirname "$0")/40-migrate.sh" vm-a >/dev/null
for vm in vm-b vm-c; do
	grep -qw "$vm" "$STATE/legacy" || "$(dirname "$0")/41-rollback.sh" "$vm" >/dev/null
done
echo "旧方式：$(cat "$STATE/legacy")；已登记：$(awk '{print $1}' "$STATE/mappings" | tr '\n' ' ')"

blocked() { # 把回显结果归纳成“被拦截”或“连通，来源 X”
	local r; r=$(cat); local e; e=$(echo "$r" | field error)
	if [ "$e" != 无 ]; then echo "被拦截"; else echo "连通，来源 $(echo "$r" | field client)"; fi
}
capture() { # 节点 网卡变量名 秒数 文件 过滤表达式：后台抓包
	on "$1" ". /etc/lab/ifaces.env; timeout $3 tcpdump -ni \$$2 -s0 -w $4 '$5' >/dev/null 2>&1 &"
}
count() { on "$1" "tcpdump -nr $2 '$3' 2>/dev/null | wc -l"; }

say "A 新旧并存"
r=$(get vm-a "http://$INTRANET_IP/")
check "A1 已迁移的 vm-a 经七层访问内网，来源仍是原来的内网 IP" 100.64.0.7 "$(echo "$r" | field client)"
check "A2 vm-a 的请求带上了 Egress 注入的凭证" 已注入 "$(echo "$r" | cred)"
check "A3 vm-a 经四层访问内网（8080 端口），来源同样是内网 IP" 100.64.0.7 "$(get vm-a "http://$INTRANET_IP:8080/" | field client)"
r=$(get vm-b "http://$INTRANET_IP/")
check "A4 仍用旧方式的 vm-b 不受影响，来源是它自己的内网 IP" 100.64.0.8 "$(echo "$r" | field client)"
check "A5 vm-b 的请求仍然没有凭证" 无 "$(echo "$r" | cred)"
r=$(get vm-a "http://$PUBLIC_IP/")
check "A6 vm-a 访问公网不经过网关，来源是 Egress" 203.0.113.20 "$(echo "$r" | field client)"

say "B 抓包：明文和密文各出现在哪一段"
capture egress IF_VM_NET 6 /tmp/b-vm.pcap "host 10.1.2.3 and host $INTRANET_IP"
capture gw-1 IF_WAN 6 /tmp/b-wan.pcap "not arp"
on vm-a "sleep 1; for i in 1 2 3; do curl -s -m 3 http://$INTRANET_IP/ >/dev/null; done; sleep 5"
n=$(count egress /tmp/b-vm.pcap "tcp port 80")
if [ "$n" -gt 0 ]; then echo "通过：B1 Egress 现在能看到 vm-a 去内网的明文 TCP（$n 个包）"; else echo "失败：B1 Egress 没有看到明文 TCP"; FAILS=$((FAILS + 1)); fi
n=$(count gw-1 /tmp/b-wan.pcap "udp port 51820")
if [ "$n" -gt 0 ]; then echo "通过：B2 网关到 vpn-server 之间是 WireGuard 的 UDP（$n 个包）"; else echo "失败：B2 没有抓到隧道的包"; FAILS=$((FAILS + 1)); fi
check "B3 承载网上没有任何去往内网服务的明文包" 0 "$(count gw-1 /tmp/b-wan.pcap "host $INTRANET_IP")"

say "C 未登记的虚拟机和失效的旧密钥"
# vm-c 停用旧隧道、删除 peer，但不登记：它既不在旧方式里，也不在映射表里。
on vm-c "systemctl disable -q --now wg-quick@wg0"
sed -i "s/\bvm-c\b//; s/  */ /g; s/^ //; s/ $//" "$STATE/legacy"
apply_server_conf >/dev/null
check "C1 未登记的 vm-c 经七层访问内网" 被拦截 "$(get vm-c "http://$INTRANET_IP/" | blocked)"
check "C2 未登记的 vm-c 经四层访问内网" 被拦截 "$(get vm-c "http://$INTRANET_IP:8080/" | blocked)"
# vm-c 用旧密钥重新拨号：peer 已删，握手不会成功。
on vm-c "systemctl start wg-quick@wg0; sleep 1; ping -c2 -W2 $INTRANET_IP >/dev/null 2>&1; sleep 4"
check "C3 vm-c 用旧密钥重新拨号，握手次数" 0 "$(on vm-c "wg show wg0 latest-handshakes | awk '{print \$2}'")"
check "C4 vm-c 用旧密钥重新拨号后访问内网" 被拦截 "$(TIMEOUT=6 get vm-c "http://$INTRANET_IP/" | blocked)"
on vm-c "systemctl stop wg-quick@wg0"

say "D 网关入口和伪造身份"
check "D1 虚拟机直连网关的 15001 端口" 不通 "$(on vm-a "nc -z -w 3 $GATEWAY_VIP 15001 >/dev/null 2>&1 && echo 通 || echo 不通")"
check "D2 服务网段上除 Egress 以外的机器连网关端口" 不通 "$(on gw-2 "nc -z -w 3 $GATEWAY_VIP 15001 >/dev/null 2>&1 && echo 通 || echo 不通")"
# 未登记的 vm-c 自带一个伪造的 PROXY 头，声称自己是 vm-a，想借 Egress 送到网关。
spoof() {
	# 发完请求后保持连接几秒再关：马上关闭写方向的话，连接会在响应回来之前被拆掉。
	on vm-c "(printf 'PROXY TCP4 10.1.2.3 $INTRANET_IP 40000 80\r\nGET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'; sleep 4) | nc -w 6 $GATEWAY_VIP 15001 2>/dev/null | grep -o '\"client\": \"[0-9.]*\"' | grep -o '[0-9.]*' || echo 无响应"
}
check "D3 vm-c 伪造 PROXY 头冒充 vm-a（Egress 有拦截规则）" 无响应 "$(spoof)"
# 对照：临时去掉 Egress 上“虚拟机不能访问服务网段”的规则，同样的伪造就会成功。
on egress "nft flush chain ip egress guard"
check "D4 对照：去掉拦截规则后，同样的伪造会被内网当成 vm-a" 100.64.0.7 "$(spoof)"
on egress "nft -f /etc/lab/egress.nft"
check "D5 恢复拦截规则后再次伪造" 无响应 "$(spoof)"

say "C（续）登记后立即可用"
register vm-c >/dev/null
r=$(get vm-c "http://$INTRANET_IP/")
check "C5 登记 vm-c 后访问内网，来源是它原来的内网 IP" 100.64.0.99 "$(echo "$r" | field client)"
check "C6 vm-c 的请求带上了凭证" 已注入 "$(echo "$r" | cred)"

say "E TLS：Egress 向内网服务发起 TLS，网关只看到密文"
r=$(get vm-a "http://$INTRANET_IP:8443/")
check "E1 vm-a 发明文请求，内网服务收到的是 TLS" true "$(echo "$r" | field tls)"
check "E2 经 TLS 的请求来源仍是 vm-a 的内网 IP" 100.64.0.7 "$(echo "$r" | field client)"
check "E3 经 TLS 的请求带上了凭证" 已注入 "$(echo "$r" | cred)"
capture gw-1 IF_SVC_NET 6 /tmp/e-tls.pcap "tcp port 15001"
on vm-a "sleep 1; for i in 1 2 3; do curl -s -m 3 http://$INTRANET_IP:8443/ >/dev/null; done; sleep 5"
check "E4 走 TLS 时，网关收到的数据里凭证出现的次数" 0 "$(on gw-1 "tcpdump -Anr /tmp/e-tls.pcap 2>/dev/null | grep -c '$CRED' || true")"
capture gw-1 IF_SVC_NET 6 /tmp/e-plain.pcap "tcp port 15001"
on vm-a "sleep 1; for i in 1 2 3; do curl -s -m 3 http://$INTRANET_IP/ >/dev/null; done; sleep 5"
n=$(on gw-1 "tcpdump -Anr /tmp/e-plain.pcap 2>/dev/null | grep -c '$CRED' || true")
if [ "$n" -gt 0 ]; then echo "通过：E5 对照：不走 TLS 时，凭证在网关上以明文可见（出现 $n 次）"; else echo "失败：E5 对照组没有在网关上看到明文凭证"; FAILS=$((FAILS + 1)); fi

say "F 回退和再次迁移"
"$(dirname "$0")/41-rollback.sh" vm-a >/dev/null
r=$(get vm-a "http://$INTRANET_IP/")
check "F1 vm-a 回退到旧方式后访问内网，来源不变" 100.64.0.7 "$(echo "$r" | field client)"
check "F2 回退后 vm-a 的请求不再有凭证" 无 "$(echo "$r" | cred)"
"$(dirname "$0")/40-migrate.sh" vm-a >/dev/null
r=$(get vm-a "http://$INTRANET_IP/")
check "F3 vm-a 再次迁移后访问内网，来源不变" 100.64.0.7 "$(echo "$r" | field client)"
check "F4 再次迁移后凭证恢复注入" 已注入 "$(echo "$r" | cred)"
finish
