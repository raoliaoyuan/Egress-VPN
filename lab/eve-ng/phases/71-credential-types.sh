#!/usr/bin/env bash
# 阶段 7（续）：按凭证类型看能做到什么。内网服务认的凭证有三类：客户端证书、令牌、静态凭证。
# 客户端证书的情况在 70-credential.sh 的 J 段已经验证；这里验证另外两类，以及不走 HTTP 的服务。
#   P 令牌：服务端按来源地址限定之后，泄露的令牌在别处用不了
#   Q 静态凭证（HTTP，所有虚拟机共用一个账号）：由 Egress 注入，轮换只改 Egress 和服务两处
#   R 不走 HTTP 的服务：口令 Egress 注入不了；客户端证书可以由 Egress 在四层代为出示
#   S 凭证已经泄露过之后，在 Egress 上摘掉一台虚拟机够不够
#   T 做完这些之后，虚拟机的磁盘上仍然没有凭证
# 8080 端口在实验里代表“服务上没有被 Egress 七层处理覆盖的入口”：Egress 对它只做四层转发，
# 虚拟机自己带的凭证会原样到达服务。泄露的凭证只有经这种入口，或者从别的主机，才用得上。
set -euo pipefail
. "$(dirname "$0")/common.sh"
ATTACKER_IP=203.0.113.81   # 临时加在 public-web 上的第二个地址，代表攻击者自己控制的站点
OTHER_HOST=vpn-server      # 内网里的另一台主机（它有一块网卡在内网），代表“从别处”

cleanup() {
	on public-web ". /etc/lab/ifaces.env; ip addr del $ATTACKER_IP/24 dev \$IF_WAN 2>/dev/null || true" || true
	[ -z "${RESTORE:-}" ] || { svc_table bound && egress_config solution >/dev/null; } || echo "注意：凭证表或 Egress 的配置没有恢复，请执行 svc_table bound 和 egress_config solution"
}
trap cleanup EXIT

# present <节点> <URL> <一整行请求头>：从节点上自己带着凭证发请求，输出回显服务的 JSON。
# 模拟“凭证已经泄露到这台机器上”。请求头从标准输入交给 curl，不出现在命令行和磁盘上。
present() { on "$1" "curl -s -m 8 -H @- '$2' <<<'$3'" 2>/dev/null || true; }
basic() { printf 'Authorization: Basic %s' "$(printf '%s' "$1" | base64 -w0)"; }
auth_headers() { jq -r '[.headers | keys[] | select(ascii_downcase == "authorization")] | length' 2>/dev/null || echo 无法解析; }
# resp <节点> <地址> <端口> <命令>…：按 Redis 协议依次发几条命令，每条的应答输出一行。
resp() {
	local node=$1 host=$2 port=$3 cmds; shift 3
	cmds=$(printf '%s\n' "$@")
	on "$node" "python3 - <<'PY'
import socket
cmds = '''$cmds'''.splitlines()
try:
    s = socket.create_connection(('$host', $port), timeout=6); f = s.makefile('rb')
    for c in cmds:
        a = c.split()
        s.sendall(b'*%d\r\n' % len(a) + b''.join(b'\$%d\r\n%s\r\n' % (len(x), x.encode()) for x in a))
        line = f.readline().decode().rstrip()
        if line.startswith('\$') and line != '\$-1': line = f.read(int(line[1:]) + 2).decode().rstrip()
        print(line or '连接被关闭')
except OSError as e:
    print('连接失败')
PY" 2>/dev/null || true
}
whoami() { tail -1 | jq -r '"\(.client) \(.identity)"' 2>/dev/null || echo 没有登录成功; }
digest() { tr -d '\n' < "$1" | sha256sum | cut -d' ' -f1; }

say "准备：全部虚拟机走新方案，Egress 用正常配置，服务端按来源地址限定"
for vm in $(cat "$STATE/legacy"); do "$(dirname "$0")/40-migrate.sh" "$vm" >/dev/null; echo "已迁移 $vm"; done
RESTORE=1
svc_table bound
egress_config solution
on public-web ". /etc/lab/ifaces.env; ip addr replace $ATTACKER_IP/24 dev \$IF_WAN"
token_a="x-egress-credential: $(cat "$STATE/creds/vm-a.intranet-svc.token")"

say "P 令牌：服务端按来源地址限定"
svc_table open
r=$(present vm-b "http://$INTRANET_IP:8080/" "$token_a")
ctrl "P0 不限定来源时，vm-b 拿着 vm-a 的令牌：服务看到的来源、认出的调用方" "${INTRA_IP[vm-b]} vm-a" "$(echo "$r" | field client) $(echo "$r" | field identity)"
ctrl "P0 不限定来源时，内网里另一台主机拿着 vm-a 的令牌，服务认出的调用方" vm-a "$(present $OTHER_HOST "http://$INTRANET_IP:8080/" "$token_a" | field identity)"
svc_table bound
r=$(present vm-b "http://$INTRANET_IP:8080/" "$token_a")
check "P1 限定之后，vm-b 拿着 vm-a 的令牌：来源、服务的判断" "${INTRA_IP[vm-b]} wrong-source" "$(echo "$r" | field client) $(echo "$r" | field identity)"
check "P2 限定之后，内网里另一台主机拿着 vm-a 的令牌" wrong-source "$(present $OTHER_HOST "http://$INTRANET_IP:8080/" "$token_a" | field identity)"
for vm in "${VMS[@]}"; do
	check "P3 限定之后，$vm 经 Egress 的正常访问不受影响" "$vm" "$(get "$vm" "http://$INTRANET_IP/" | field identity)"
done
r=$(present vm-a "http://$INTRANET_IP:8080/" "$token_a")
check "P4 vm-a 拿回自己的令牌直接用：来源和身份都还是它自己，没有多出权限" "${INTRA_IP[vm-a]} vm-a" "$(echo "$r" | field client) $(echo "$r" | field identity)"

say "Q 静态凭证（HTTP，所有虚拟机共用账号 $SHARED_USER）"
for vm in "${VMS[@]}"; do
	r=$(get "$vm" "http://$INTRANET_IP:8081/")
	check "Q1 $vm 不带任何凭证访问 8081：来源地址、服务认出的账号" "${INTRA_IP[$vm]} $SHARED_USER" "$(echo "$r" | field client) $(echo "$r" | field account)"
done
check "Q2 vm-b 自带一个伪造的 Authorization，服务认出的仍是" "$SHARED_USER" "$(get vm-b "http://$INTRANET_IP:8081/" "-H 'Authorization: Basic Zm9yZ2VkOmZvcmdlZA=='" | field account)"
check "Q3 正常响应里出现的凭证数" 0 "$(body vm-a "http://$INTRANET_IP:8081/" | tokens_in)"
r=$(get vm-a "http://$ATTACKER_IP:8081/reflect")
check "Q4 vm-a 访问攻击者站点的同一个端口：连通，站点收到的 Authorization 个数" "public-web 0" "$(echo "$r" | field server) $(echo "$r" | auth_headers)"
leak "Q5 内网服务回显请求头时，静态凭证同样回到了 vm-a（和令牌一样的固有限制）" "$(body vm-a "http://$INTRANET_IP:8081/reflect" | tokens_in)"
# 轮换：换掉口令，只改服务端的凭证表和 Egress 的配置，虚拟机上什么都不动。
old=$(cat "$STATE/creds/intranet-svc.shared")
(umask 077; printf '%s:lab-static-%s\n' "$SHARED_USER" "$(openssl rand -hex 12)" > "$STATE/creds/intranet-svc.shared")
svc_table bound
egress_config solution >/dev/null
for vm in "${VMS[@]}"; do
	check "Q6 轮换之后 $vm 的访问（虚拟机上没有做任何改动）" "$SHARED_USER" "$(get "$vm" "http://$INTRANET_IP:8081/" | field account)"
done
check "Q7 轮换之后，旧口令从 vm-a 直接拿去用" unknown "$(present vm-a "http://$INTRANET_IP:8080/" "$(basic "$old")" | field account)"
shared_now=$(basic "$(cat "$STATE/creds/intranet-svc.shared")")

say "R 不走 HTTP 的服务（Redis 协议，6379 靠口令，6380 靠客户端证书）"
# 试验：让 Envoy 的 Redis 代理替虚拟机登录。它能发 AUTH，但它的上游连接是代理自己建的，
# 不对应某一条虚拟机的连接，开头的 PROXY 头里没有虚拟机的地址，网关不知道该替谁、连到哪里。
egress_config solution "${VMS[*]}" --redis-inject >/dev/null
# 抓包前先删掉上次的文件，否则这次写不进去（原因见 50-verify.sh 的 capture）。
on gw-1 ". /etc/lab/ifaces.env; rm -f /tmp/r.pcap; timeout 8 tcpdump -ni \$IF_SVC_NET -s0 -w /tmp/r.pcap 'tcp port 15001' >/dev/null 2>&1 &"
on intranet-svc "rm -f /tmp/r.pcap; timeout 8 tcpdump -ni any -s0 -w /tmp/r.pcap 'tcp port 6379' >/dev/null 2>&1 &"
sleep 1
check "R1 由 Egress 上的 Redis 代理替虚拟机登录，vm-a 不带口令发命令，收到" "-upstream failure" "$(resp vm-a "$INTRANET_IP" 6379 "GET whoami" | head -1)"
sleep 8
# PROXY v2 头：12 字节签名之后的一个字节，20 是 LOCAL（不带地址），21 是 PROXY（带着来源和目的地址）。
proxy_kind() { on gw-1 "tcpdump -xnr /tmp/r.pcap 'tcp[tcpflags] & tcp-push != 0' 2>/dev/null | grep -v '^[0-9]' | tr -d ' \t\n' | sed -E 's/0x[0-9a-f]{4}://g' | grep -o '0d0a0d0a000d0a515549540a..' | head -1 | tail -c 3"; }
check "R2 这条连接到网关时，开头的 PROXY 头的类型（20 不带地址，21 带地址）" 20 "$(proxy_kind)"
check "R3 内网服务上这段时间的抓包文件、里面 6379 端口的包数" "已写出 0" "$(on intranet-svc "[ -s /tmp/r.pcap ] && echo 已写出 || echo 没有写出; tcpdump -nr /tmp/r.pcap 2>/dev/null | wc -l" | tr '\n' ' ' | sed 's/ $//')"
egress_config solution >/dev/null
# 所以靠口令的非 HTTP 服务，口令只能由虚拟机自己带（这是例外，要单独列出来）。能做的是按来源地址限定。
pass_a=$(cat "$STATE/creds/vm-a.intranet-svc.pass")
on gw-1 ". /etc/lab/ifaces.env; rm -f /tmp/r.pcap; timeout 5 tcpdump -ni \$IF_SVC_NET -s0 -w /tmp/r.pcap 'tcp port 15001' >/dev/null 2>&1 &"
sleep 1
check "R4 口令在 vm-a 手里，四层转发：服务看到的来源、认出的调用方" "${INTRA_IP[vm-a]} vm-a" "$(resp vm-a "$INTRANET_IP" 6379 "AUTH $pass_a" "GET whoami" | whoami)"
sleep 5
check "R4 作为对比，四层转发的这条连接的 PROXY 头类型" 21 "$(proxy_kind)"
check "R5 vm-b 拿着 vm-a 的口令去登录" "-WRONGSOURCE" "$(resp vm-b "$INTRANET_IP" 6379 "AUTH $pass_a" | head -1 | cut -d' ' -f1)"
check "R6 内网里另一台主机拿着 vm-a 的口令去登录" "-WRONGSOURCE" "$(resp $OTHER_HOST "$INTRANET_IP" 6379 "AUTH $pass_a" | head -1 | cut -d' ' -f1)"
# 服务认客户端证书时，Egress 不需要看懂协议：在四层替虚拟机发起 TLS、出示它的证书就行。
for vm in "${VMS[@]}"; do
	r=$(resp "$vm" "$INTRANET_IP" 6380 "GET whoami" | tail -1)
	check "R7 $vm 不带任何凭证发明文到 6380：服务收到 TLS、来源、从证书认出的调用方" "true ${INTRA_IP[$vm]} $vm" \
		"$(echo "$r" | jq -r '"\(.tls) \(.client) \(.client_cert)"' 2>/dev/null || echo "$r")"
done

say "S 凭证已经泄露过之后，在 Egress 上摘掉 vm-c"
token_c="x-egress-credential: $(cat "$STATE/creds/vm-c.intranet-svc.token")"
egress_config solution "vm-a vm-b" >/dev/null
check "S1 摘掉之后 vm-c 经 Egress 访问：令牌、共用账号都不再给它" "无 无" "$(get vm-c "http://$INTRANET_IP/" | field identity) $(get vm-c "http://$INTRANET_IP:8081/" | field account)"
check "S2 摘掉之后 vm-c 发明文到 6380（客户端证书不再替它出示）" 没有应答 "$(resp vm-c "$INTRANET_IP" 6380 "GET whoami" | grep -q client_cert && echo 有应答 || echo 没有应答)"
ctrl "S3 但 vm-c 之前拿到过自己的令牌的话，从没被覆盖的入口还能用" vm-c "$(present vm-c "http://$INTRANET_IP:8080/" "$token_c" | field identity)"
on intranet-svc "sed -i '/^$(digest "$STATE/creds/vm-c.intranet-svc.token") /d' /etc/lab/tokens"
check "S4 在服务端也作废这个令牌之后" unknown "$(present vm-c "http://$INTRANET_IP:8080/" "$token_c" | field identity)"
ctrl "S5 共用的静态凭证泄露过的话，摘掉 vm-c 拦不住它，服务端也没法只作废它一台" "$SHARED_USER" "$(present vm-c "http://$INTRANET_IP:8080/" "$shared_now" | field account)"
check "S6 来源限定仍然有效：同一份共用凭证拿到内网里另一台主机上" wrong-source "$(present $OTHER_HOST "http://$INTRANET_IP:8080/" "$shared_now" | field account)"
svc_table bound
egress_config solution >/dev/null
r=$(get vm-c "http://$INTRANET_IP/")
check "S7 恢复之后 vm-c 的令牌和客户端证书" "vm-c vm-c" "$(echo "$r" | field identity) $(resp vm-c "$INTRANET_IP" 6380 "GET whoami" | tail -1 | jq -r .client_cert 2>/dev/null)"

say "T 做完这些之后，虚拟机的磁盘上仍然没有凭证"
for vm in "${VMS[@]}"; do
	scan=$(scan_fs "$vm")
	[ "$(echo "$scan" | tail -1)" = scanned ] || { echo "失败：T1 $vm 的文件系统没有扫完"; FAILS=$((FAILS + 1)); continue; }
	check "T1 $vm 的文件系统里含令牌或静态凭证的文件数" 0 "$(echo "$scan" | grep -c '^token ' || true)"
done
finish
