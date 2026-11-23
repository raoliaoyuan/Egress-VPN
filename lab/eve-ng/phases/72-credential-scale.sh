#!/usr/bin/env bash
# 阶段 7.2：凭证的规模化（先执行 80-scale-a.sh；块 3 走数据面 A）。跑完把 Egress 恢复成原来的配置。
# 原来的参考实现给每台虚拟机、每个服务端口各生成一条过滤链，凭证直接写在 Envoy 的配置里。这里验证两件事：
#
# 一、“规则按服务写，数据按身份查”。Envoy 的配置里每个服务端口只有一条规则，命中之后去问本机的凭证代理
#     （cred-agent.py），它按“来源地址 × 服务”查表。配置里没有凭证，也没有任何一台虚拟机的地址。
# 二、客户端证书改成“一张证书加身份声明”。Egress 用自己的一张证书向服务发起 TLS，每个请求带一份
#     凭证代理签发的短期声明；内网服务前面放一个校验代理（config/intranet-verifier/envoy.yaml），
#     验证书、验声明、验“声明里的内网 IP 等于连接的来源地址”，通过后把认出的调用方交给服务。
#
#   C 配置的规模：原来的做法每多一台虚拟机多几条过滤链；新做法和虚拟机数量无关，里面没有凭证；
#   A 按身份查：令牌、TLS 上的令牌、共用账号；覆盖虚拟机自带的头；表里没有的不带凭证；
#   U 更新和故障：换表不重启 Envoy、不断连接；坏的表不生效；凭证代理停了，指定服务的请求失败、别的不受影响；
#   D 身份声明：三台虚拟机和模拟的身份都被服务认成它自己；虚拟机改不了认出的结果；声明到不了服务手里；
#   R 重放和伪造（对照）：拿到别人的声明之后，没有 Egress 的证书、来源地址不对、过期、受众不对、签名不对，都被拒绝；
#   G 网关改了地址（对照）：只按来源地址认的服务会认错人，按声明认的服务拒绝；
#   L 规模和开销：十万个身份都经声明访问一遍；每个请求多一次本机查询的开销。
# 用法：72-credential-scale.sh [C A U D R G L 里的若干个，默认全部]
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/bench-lib.sh"
. "$(dirname "$0")/scale-lib.sh"
scale_on || die "还不是规模化形态，先执行 80-scale-a.sh"
b_on && die "块 3 现在走数据面 B；先执行 30-deploy-solution.sh 和 80-scale-a.sh"
SECTIONS=${*:-C A U D R G L}
want() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }
PROBE_HOST=rtr-core            # 内网里的另一台主机，用来模拟“从别处重放”。它在内网一侧的地址是 10.200.5.1
PROBE_ADDR=10.200.5.1
VERIFIED=9444                  # 校验代理的端口，后面是回显服务
VERIFIED_FAST=9445             # 校验代理的另一个端口，后面是压测用的服务端
JWT_RE='eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
gen() { python3 "$FILES/gen-egress-envoy.py" solution --state "$STATE" --scale "$@"; }
chains() { python3 -c 'import sys, yaml; c = yaml.safe_load(sys.stdin)["static_resources"]; print(sum(len(l["filter_chains"]) for l in c["listeners"]), len(c["clusters"]))'; }

# ---------- 部署 ----------
# 每台 Egress 一把签名密钥、一张自己的证书（客户端 CA 签发，带名字 egress.lab）。
make_keys() {
	local eg
	for eg in "${EGRESS_NODES[@]}"; do
		[ -s "$STATE/creds/declare-$eg.key" ] || (umask 077; openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "$STATE/creds/declare-$eg.key" 2>/dev/null)
		[ -s "$STATE/tls/egress-$eg.pem" ] || (cd "$STATE/tls" && umask 077 \
			&& openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "egress-$eg.key" -out "egress-$eg.csr" -subj "/CN=$eg" 2>/dev/null \
			&& printf 'extendedKeyUsage=clientAuth\nsubjectAltName=DNS:egress.lab\n' > egress.ext \
			&& openssl x509 -req -in "egress-$eg.csr" -CA client-ca.pem -CAkey client-ca.key -CAcreateserial -days 365 -extfile egress.ext -out "egress-$eg.pem" 2>/dev/null)
	done
}
# 地址分配表之外的那张表：每台虚拟机在每个服务上用什么。三台真实的虚拟机有固定凭证，也有声明；
# 模拟的身份（块 2、块 3）只有声明，另外在压测用的端口上各有一个占位的令牌，用来量查表的开销。
# 第二个参数是不给凭证的虚拟机（用来验证“表里没有就不带凭证”）。
gen_table() { # 版本 [排除的虚拟机]
	python3 - "$1" "${2:-}" "$STATE" "$FARM_PER_BLOCK" <<'PY'
import base64, hashlib, ipaddress, os, sys
version, skip, state, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
vms = {"vm-a": ("10.1.2.3", "100.64.0.7"), "vm-b": ("10.1.2.4", "100.64.0.8"), "vm-c": ("10.1.2.99", "100.64.0.99")}
read = lambda name: open(os.path.join(state, "creds", name)).read().strip()
print("# version", version)
basic = "Basic " + base64.b64encode(read("intranet-svc.shared").encode()).decode()
for vm, (real, intra) in vms.items():
    if vm == skip:
        continue
    tok = read(f"{vm}.intranet-svc.token")
    for port in (80, 8443, 8090):
        print(real, f"intranet-svc:{port}", "header", "x-egress-credential", tok)
    print(real, "intranet-svc:8081", "header", "authorization", basic)
    print(real, "public-web:80", "header", "x-egress-credential", read(f"{vm}.public-web.token"))
    for port in (9444, 9445):
        print(real, f"intranet-svc:{port}", "declare", intra, vm)
for real0, intra0 in (("10.2.0.0", "100.66.0.0"), ("10.3.0.0", "100.67.0.0")):
    r, i = int(ipaddress.ip_address(real0)), int(ipaddress.ip_address(intra0))
    for k in range(1, n + 1):
        real, intra = str(ipaddress.ip_address(r + k)), str(ipaddress.ip_address(i + k))
        print(real, "intranet-svc:9444", "declare", intra, "farm-" + real)
        print(real, "intranet-svc:9445", "declare", intra, "farm-" + real)
        print(real, "intranet-svc:8090", "header", "x-egress-credential", "lab-token-" + hashlib.sha256(real.encode()).hexdigest()[:24])
PY
}
agent_version() { on "$1" "curl -s -m 2 http://127.0.0.1:9191/version" 2>/dev/null | jq -r "${2:-.version}" 2>/dev/null || echo 无; }
# push_table <版本> [排除的虚拟机]：生成表、下发到两台 Egress（先写成临时文件，再用重命名替换），等凭证代理报告新版本生效。
push_table() {
	local eg i t0
	(umask 077; gen_table "$1" "${2:-}" > "$STATE/cred-table.tmp")
	t0=$(date +%s.%N)
	for eg in "${EGRESS_NODES[@]}"; do
		put_secret "$eg" "$STATE/cred-table.tmp" /etc/lab/cred-table.new
		on "$eg" "mv /etc/lab/cred-table.new /etc/lab/cred-table"
	done
	for i in $(seq 1 40); do
		[ "$(agent_version egress-1) $(agent_version egress-2)" = "$1 $1" ] && break
		sleep 0.25
	done
	PUSH_SECS=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
	rm -f "$STATE/cred-table.tmp"
	[ "$(agent_version egress-1) $(agent_version egress-2)" = "$1 $1" ]
}
deploy_verifier() { # [nocheck]：nocheck 时去掉“声明里的地址等于来源地址”这一条，只用于对照
	if [ "${1:-}" = nocheck ]; then
		python3 - "$REPO/config/intranet-verifier/envoy.yaml" > "$STATE/verifier.tmp" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
for l in c["static_resources"]["listeners"]:
    hcm = l["filter_chains"][0]["filters"][0]["typed_config"]
    hcm["http_filters"] = [f for f in hcm["http_filters"] if f["name"] != "envoy.filters.http.rbac"]
yaml.safe_dump(c, sys.stdout, sort_keys=False)
PY
	else
		cp "$REPO/config/intranet-verifier/envoy.yaml" "$STATE/verifier.tmp"
	fi
	put intranet-svc "$STATE/verifier.tmp" /etc/envoy/verifier.new.yaml
	rm -f "$STATE/verifier.tmp"
	on intranet-svc '/usr/local/bin/envoy --mode validate -c /etc/envoy/verifier.new.yaml -l error > /tmp/verifier-validate.log 2>&1 || { echo "校验代理的配置没有通过校验："; tail -3 /tmp/verifier-validate.log; exit 1; }
mv /etc/envoy/verifier.new.yaml /etc/envoy/verifier.yaml
systemctl restart verifier.service
for _ in $(seq 1 20); do [ "$(ss -Hltn "sport = :9444" | wc -l)" -ge 1 ] && break; sleep 0.5; done
[ "$(ss -Hltn "sport = :9444" | wc -l)" -ge 1 ]'
}
deploy() {
	local eg
	make_keys
	say "凭证代理：两台 Egress 各一个，各有自己的签名密钥和证书"
	for eg in "${EGRESS_NODES[@]}"; do
		put "$eg" "$FILES/cred-agent.py" /usr/local/bin/cred-agent.py
		put_secret "$eg" "$STATE/creds/declare-$eg.key" /etc/lab/declare.key
		put "$eg" "$STATE/tls/egress-$eg.pem" /etc/lab/egress-cert.pem
		put_secret "$eg" "$STATE/tls/egress-$eg.key" /etc/lab/egress-cert.key
		cat > "$STATE/tmp" <<UNIT
[Unit]
Description=Lab credential agent
After=lab-init.service
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/cred-agent.py --table /etc/lab/cred-table --sign-key /etc/lab/declare.key --kid $eg --issuer egress.lab --ttl 120
Restart=always
RestartSec=1
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
		put "$eg" "$STATE/tmp" /etc/systemd/system/cred-agent.service
		on "$eg" "chmod 755 /usr/local/bin/cred-agent.py; touch /etc/lab/cred-table; chmod 600 /etc/lab/cred-table
systemctl daemon-reload; systemctl enable -q cred-agent.service; systemctl restart cred-agent.service"
		on "$eg" "python3 /usr/local/bin/cred-agent.py --jwks --sign-key /etc/lab/declare.key --kid $eg" > "$STATE/jwks-$eg.tmp"
	done
	jq -s '{keys: map(.keys[])}' "$STATE"/jwks-*.tmp > "$STATE/creds/declare-jwks.json"
	rm -f "$STATE"/jwks-*.tmp "$STATE/tmp"
	say "内网服务一侧：校验代理（只有各台 Egress 的公钥），回显服务多一个只给校验代理用的本机端口"
	put intranet-svc "$FILES/echo-server.py" /opt/lab/echo-server.py
	put intranet-svc "$STATE/creds/declare-jwks.json" /etc/lab/declare-jwks.json
	cat > "$STATE/tmp" <<UNIT
[Unit]
Description=Lab verifying proxy in front of intranet services
After=lab-init.service
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/local/bin/envoy -c /etc/envoy/verifier.yaml --disable-hot-restart -l warn --log-path /var/log/verifier.log
Restart=always
RestartSec=1
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
	put intranet-svc "$STATE/tmp" /etc/systemd/system/verifier.service
	rm -f "$STATE/tmp"
	on intranet-svc "mkdir -p /etc/envoy; systemctl daemon-reload; systemctl enable -q verifier.service; systemctl restart echo.service"
	deploy_verifier
	svc_table bound
	say "地址和凭证的表：三台虚拟机加 $((FARM_PER_BLOCK * 2)) 个模拟的身份"
	push_table v1 || die "凭证代理没有加载表"
	echo "  下发并生效用了 $PUSH_SECS 秒；egress-1 上 $(agent_version egress-1 .entries) 条，凭证代理占内存 $(on egress-1 "ps -o rss= -p \$(systemctl show -p MainPID --value cred-agent.service) | awk '{printf \"%d MB\", \$1 / 1024}'")"
	say "两台 Egress：改成按身份查的配置"
	egress_files
	egress_config solution "" --cred-agent
}
restore() {
	say "恢复：Egress 换回原来的配置（逐台虚拟机生成过滤链）"
	deploy_verifier >/dev/null 2>&1 || true
	egress_config solution || true
}

# KEEP=1：跑完不恢复，留着按身份查的配置，排查问题时用
[ -z "${KEEP:-}" ] || restore() { echo "KEEP=1：保留按身份查的配置，没有恢复"; }

if want C; then
	say "C 配置的规模"
	declare -A SIZE CH
	i=0
	for vms in "--vm vm-a=10.1.2.3" "--vm vm-a=10.1.2.3 --vm vm-b=10.1.2.4" "--vm vm-a=10.1.2.3 --vm vm-b=10.1.2.4 --vm vm-c=10.1.2.99"; do
		i=$((i + 1))
		# shellcheck disable=SC2086
		gen $vms > "$STATE/cfg.tmp"
		SIZE[$i]=$(wc -c < "$STATE/cfg.tmp"); CH[$i]=$(chains < "$STATE/cfg.tmp")
		echo "  原来的做法，$i 台虚拟机：$(echo "${CH[$i]}" | cut -d' ' -f1) 条过滤链、$(echo "${CH[$i]}" | cut -d' ' -f2) 个上游集群，${SIZE[$i]} 字节"
	done
	per_vm=$(( $(echo "${CH[3]}" | cut -d' ' -f1) - $(echo "${CH[2]}" | cut -d' ' -f1) ))
	check "C 原来的做法每多一台虚拟机，过滤链多出的条数是固定的（2 到 3 台和 1 到 2 台相同）" "$per_vm" "$(( $(echo "${CH[2]}" | cut -d' ' -f1) - $(echo "${CH[1]}" | cut -d' ' -f1) ))"
	echo "  每多一台虚拟机：多 $per_vm 条过滤链、$(( $(echo "${CH[3]}" | cut -d' ' -f2) - $(echo "${CH[2]}" | cut -d' ' -f2) )) 个上游集群、$(( SIZE[3] - SIZE[2] )) 字节；按这个比例十万台是 $(( per_vm * 100000 )) 条、约 $(( (SIZE[3] - SIZE[2]) * 100000 / 1048576 )) MB"
	gen --cred-agent > "$STATE/cfg.tmp"
	a=$(sha256sum < "$STATE/cfg.tmp")
	echo "  按身份查：$(chains < "$STATE/cfg.tmp" | cut -d' ' -f1) 条过滤链、$(chains < "$STATE/cfg.tmp" | cut -d' ' -f2) 个上游集群，$(wc -c < "$STATE/cfg.tmp") 字节"
	check "C 按身份查的配置里出现的凭证个数" 0 "$(tokens_in < "$STATE/cfg.tmp")"
	check "C 按身份查的配置里出现的虚拟机地址个数" 0 "$(grep -cE '10\.1\.2\.(3|4|99)\b' "$STATE/cfg.tmp" || true)"
	check "C 按身份查的配置和给不给虚拟机清单无关（带三台虚拟机生成的和不带的完全相同）" "$a" "$(gen --cred-agent --vm vm-a=10.1.2.3 --vm vm-b=10.1.2.4 --vm vm-c=10.1.2.99 | sha256sum)"
	rm -f "$STATE/cfg.tmp"
fi

want A || want U || want D || want R || want G || want L || finish
trap restore EXIT
deploy

if want A; then
	say "A 按身份查"
	for eg in "${EGRESS_NODES[@]}"; do
		check "A $eg 的 Envoy 配置里的凭证个数、虚拟机地址个数" "0 0" "$(on "$eg" "grep -oE '$TOKEN_RE' /etc/envoy/envoy.yaml | sort -u | wc -l; grep -cE '10\.1\.2\.(3|4|99)\b' /etc/envoy/envoy.yaml" | tr '\n' ' ' | sed 's/ $//')"
	done
	for vm in "${VMS[@]}"; do
		r=$(get "$vm" "http://$INTRANET_IP/")
		check "A $vm 明文 HTTP 加令牌：来源和认出的身份" "${INTRA_IP[$vm]} $vm" "$(echo "$r" | field client) $(echo "$r" | field identity)"
		r=$(get "$vm" "http://$INTRANET_IP:8443/")
		check "A $vm 由 Egress 发起 TLS 加令牌：认出的身份" "$vm" "$(echo "$r" | field identity)"
		check "A $vm 共用账号：认出的账号" "$SHARED_USER" "$(get "$vm" "http://$INTRANET_IP:8081/" | field account)"
	done
	r=$(get vm-a "http://$PUBLIC_IP/")
	check "A vm-a 访问公网上的指定服务：凭证是它在那个服务上的那一份" "vm-a 203.0.113.20" "$(echo "$r" | field identity) $(echo "$r" | field client)"
	check "A vm-a 自带一个假的凭证头，被覆盖成它自己的" vm-a "$(get vm-a "http://$INTRANET_IP/" "-H 'x-egress-credential: lab-token-000000000000000000000000'" | field identity)"
	check "A 表里没有凭证的来源（块 2 的 10.2.0.5）访问同一个服务：不带凭证" 无 "$(farm_get 10.2.0.5 "http://$INTRANET_IP/" | field identity)"
	out=$(on vm-farm "curl -s -m 6 --interface 10.2.0.5 -H 'x-egress-credential: lab-token-000000000000000000000000' 'http://$INTRANET_IP/'" 2>/dev/null || true)
	check "A 它自带一个凭证头：被删掉，服务没有看到任何凭证" 无 "$(echo "$out" | field identity)"
	check "A 目的地址是公网、Host 写成内网服务的名字：不转发" 404 "$(code vm-a "http://$PUBLIC_IP/" "-H 'Host: intranet-svc'")"
fi

if want U; then
	say "U 更新和故障"
	pid() { on "$1" "systemctl show -p MainPID -p ActiveEnterTimestampMonotonic envoy.service | tr '\n' ' '"; }
	before1=$(pid egress-1); before2=$(pid egress-2)
	stream_bg vm-farm upd --target "$INTRANET_IP:$ECHO_PORT" --src-base 10.2.1.1 --count 40 --duration 30
	sleep 3
	push_table v2 vm-c || echo "  v2 没有生效"
	echo "  去掉 vm-c 的表：下发并生效 $PUSH_SECS 秒"
	check "U 去掉 vm-c 之后，它的请求不带凭证" 无 "$(get vm-c "http://$INTRANET_IP/" | field identity)"
	check "U vm-a 不受影响" vm-a "$(get vm-a "http://$INTRANET_IP/" | field identity)"
	push_table v3 || echo "  v3 没有生效"
	echo "  加回 vm-c 的表：下发并生效 $PUSH_SECS 秒"
	check "U 加回之后 vm-c 又带上了自己的凭证" vm-c "$(get vm-c "http://$INTRANET_IP/" | field identity)"
	# 一份有错的表：凭证代理应当保留旧表
	for eg in "${EGRESS_NODES[@]}"; do
		on "$eg" "{ echo '# version bad'; echo 'this line is not valid'; } > /etc/lab/cred-table.new; chmod 600 /etc/lab/cred-table.new; mv /etc/lab/cred-table.new /etc/lab/cred-table"
	done
	sleep 2
	check "U 下发一份有错的表：两台凭证代理生效的版本仍是上一份" "v3 v3" "$(agent_version egress-1) $(agent_version egress-2)"
	check "U 这时 vm-a 照常" vm-a "$(get vm-a "http://$INTRANET_IP/" | field identity)"
	push_table v4 || echo "  v4 没有生效"
	r=$(stream_wait vm-farm upd)
	check "U 四次换表期间，经 Egress 的 40 条长连接断了几条" 0 "$(fj "$r" .broken)"
	check "U 两台 Egress 的 Envoy 都没有重启（进程号和启动时刻不变）" "$before1|$before2" "$(pid egress-1)|$(pid egress-2)"

	holder=$(access_holder "$ACCESS_VIP")
	on "$holder" "systemctl stop cred-agent.service"
	check "U 凭证代理停了：指定服务的请求失败（不会不带凭证转发出去）" 403 "$(code vm-a "http://$INTRANET_IP/")"
	check "U 凭证代理停了：没有规则的端口不受影响（内网 8080，四层转发）" "${INTRA_IP[vm-a]}" "$(get vm-a "http://$INTRANET_IP:8080/" | field client)"
	check "U 凭证代理停了：访问公网的其他站点不受影响" 200 "$(code vm-a "http://$PUBLIC_IP:8080/")"
	on "$holder" "systemctl start cred-agent.service"
	for _ in $(seq 1 20); do [ "$(agent_version "$holder")" = v4 ] && break; sleep 0.5; done
	check "U 凭证代理重新启动后从本地的表恢复，vm-a 照常" vm-a "$(get vm-a "http://$INTRANET_IP/" | field identity)"
fi

# 从凭证代理取一份声明（在 Egress 本机上问，等于控制面的视角）。只在操作机的变量里，不落到虚拟机上。
declaration() { # Egress 来源地址 服务
	on "$1" "curl -s -m 2 -D - -o /dev/null -H 'x-lab-source: $2' -H 'x-lab-service: $3' http://127.0.0.1:9191/lookup/" | tr -d '\r' | awk 'tolower($1) == "x-egress-identity:" {print $2}'
}
# mint <Egress> <声明的 JSON> [密钥文件]：离线签一份声明
mint() { on "$1" "python3 /usr/local/bin/cred-agent.py --mint '$2' --sign-key ${3:-/etc/lab/declare.key} --kid $1"; }
# probe <curl 的参数>：从内网里的另一台主机访问校验代理，输出 HTTP 状态码；握手失败输出“握手被拒绝”
probe() {
	local c
	c=$(on "$PROBE_HOST" "curl -sk -m 5 -o /tmp/probe.out -w '%{http_code}' $* https://$INTRANET_IP:$VERIFIED/ 2>/dev/null" 2>/dev/null) || true
	[ "$c" = 000 ] || [ -z "$c" ] && echo 握手被拒绝 || echo "$c"
}

if want D; then
	say "D 身份声明：一张证书，是谁发的由声明说明"
	for vm in "${VMS[@]}"; do
		r=$(get "$vm" "http://$INTRANET_IP:$VERIFIED/")
		check "D $vm：服务认出的调用方、它的内网 IP、连接的来源" "$vm ${INTRA_IP[$vm]} ${INTRA_IP[$vm]}" "$(echo "$r" | jq -r '"\(.declared) \(.declared_ip) \(.forwarded_for)"' 2>/dev/null)"
	done
	r=$(farm_get 10.2.0.5 "http://$INTRANET_IP:$VERIFIED/")
	check "D 块 2 的身份 10.2.0.5（声明由 egress-1 签）" "farm-10.2.0.5 100.66.0.5" "$(echo "$r" | jq -r '"\(.declared) \(.declared_ip)"' 2>/dev/null)"
	r=$(farm_get 10.3.0.5 "http://$INTRANET_IP:$VERIFIED/")
	check "D 块 3 的身份 10.3.0.5（声明由 egress-2 签，经另一个网关单元）" "farm-10.3.0.5 100.67.0.5" "$(echo "$r" | jq -r '"\(.declared) \(.declared_ip)"' 2>/dev/null)"
	r=$(get vm-b "http://$INTRANET_IP:$VERIFIED/" "-H 'x-verified-vm: vm-a' -H 'x-verified-vm-ip: 100.64.0.7' -H 'x-egress-identity: not-a-token'")
	check "D vm-b 自带“我是 vm-a”的请求头和一份假声明：服务认出的仍是 vm-b" "vm-b 100.64.0.8" "$(echo "$r" | jq -r '"\(.declared) \(.declared_ip)"' 2>/dev/null)"
	r=$(body vm-a "http://$INTRANET_IP:$VERIFIED/reflect")
	check "D 服务把收到的请求头原样返回：里面的声明个数（校验代理验完就拿掉了）" 0 "$(echo "$r" | grep -cE "$JWT_RE" || true)"
	check "D 服务没有收到声明本身" no "$(echo "$r" | jq -r .saw_declaration 2>/dev/null)"
	d1=$(declaration egress-1 10.1.2.3 "intranet-svc:$VERIFIED"); d2=$(declaration egress-1 10.1.2.3 "intranet-svc:$VERIFIED")
	check "D 同一台虚拟机对同一个服务，有效期内连取两次是同一份声明（不是每个请求签一次）" 相同 "$([ -n "$d1" ] && [ "$d1" = "$d2" ] && echo 相同 || echo 不同)"
	check "D 虚拟机自己对这个端口发起 TLS（想绕开 Egress 自己出示东西）：连不上" 连不上 "$(on vm-b "curl -sk -m 5 -o /dev/null https://$INTRANET_IP:$VERIFIED/ && echo 连上了 || echo 连不上")"
fi

if want R; then
	say "R 重放和伪造（对照）：从内网里的另一台主机（$PROBE_ADDR）拿着 vm-a 的声明去访问"
	jwt=$(declaration egress-1 10.1.2.3 "intranet-svc:$VERIFIED")
	[ -n "$jwt" ] || die "没有取到声明"
	put "$PROBE_HOST" "$STATE/tls/client-vm-a.pem" /tmp/probe/vm-a.pem
	put_secret "$PROBE_HOST" "$STATE/tls/client-vm-a.key" /tmp/probe/vm-a.key
	put "$PROBE_HOST" "$STATE/tls/egress-egress-1.pem" /tmp/probe/egress.pem
	put_secret "$PROBE_HOST" "$STATE/tls/egress-egress-1.key" /tmp/probe/egress.key
	EC="--cert /tmp/probe/egress.pem --key /tmp/probe/egress.key"
	check "R 只有声明，没有任何证书" 握手被拒绝 "$(probe "-H 'x-egress-identity: $jwt'")"
	check "R 声明加 vm-a 原来那张客户端证书（同一个 CA 签的，但不是 Egress 的）" 握手被拒绝 "$(probe "--cert /tmp/probe/vm-a.pem --key /tmp/probe/vm-a.key -H 'x-egress-identity: $jwt'")"
	check "R 声明加 Egress 的证书，但来源地址不是 vm-a 的内网 IP" 403 "$(probe "$EC -H 'x-egress-identity: $jwt'")"
	deploy_verifier nocheck
	c=$(probe "$EC -H 'x-egress-identity: $jwt'")
	ctrl "R 去掉“声明里的地址等于来源地址”这一条之后，同样的请求被当成 vm-a 放行" "200 vm-a" "$c $(on "$PROBE_HOST" "cat /tmp/probe.out" | field declared)"
	deploy_verifier
	check "R 恢复这一条之后又被拒绝" 403 "$(probe "$EC -H 'x-egress-identity: $jwt'")"
	check "R 有 Egress 的证书，不带声明" 401 "$(probe "$EC")"
	now=$(date +%s)
	claims() { jq -cn --arg iss "${1:-egress.lab}" --arg aud "${2:-intranet-svc:$VERIFIED}" --arg ip "$PROBE_ADDR" --argjson iat "${3:-$now}" --argjson exp "${4:-$((now + 120))}" \
		'{iss: $iss, aud: $aud, sub: "probe", vm_ip: $ip, iat: $iat, exp: $exp}'; }
	good=$(mint egress-1 "$(claims)")
	ctrl "R 一份各项都对的声明（地址写的就是这台主机）：放行。说明下面几项被拒绝是因为各自那一处不对" "200 probe" "$(probe "$EC -H 'x-egress-identity: $good'") $(on "$PROBE_HOST" "cat /tmp/probe.out" | field declared)"
	check "R 过期的声明" 401 "$(probe "$EC -H 'x-egress-identity: $(mint egress-1 "$(claims egress.lab "intranet-svc:$VERIFIED" $((now - 600)) $((now - 300)))")'")"
	check "R 受众是另一个服务的声明" 403 "$(probe "$EC -H 'x-egress-identity: $(mint egress-1 "$(claims egress.lab "intranet-svc:$VERIFIED_FAST")")'")"
	check "R 签发者不对的声明" 401 "$(probe "$EC -H 'x-egress-identity: $(mint egress-1 "$(claims someone-else)")'")"
	on egress-1 "(umask 077; openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out /tmp/other.key 2>/dev/null)"
	check "R 用另一把密钥签的声明" 401 "$(probe "$EC -H 'x-egress-identity: $(mint egress-1 "$(claims)" /tmp/other.key)'")"
	on egress-1 "rm -f /tmp/other.key"
	on "$PROBE_HOST" "rm -rf /tmp/probe /tmp/probe.out"
fi

if want G; then
	say "G 网关改了地址（对照）：在承载单元 1 的网关上把 vm-b 的内网 IP 改成 vm-a 的"
	gw=$(unit_holder "$GATEWAY_VIP")
	on "$gw" "nft -f - <<'NFT'
delete element ip vpngw vm2intra { ${REAL_IP[vm-b]} }
add element ip vpngw vm2intra { ${REAL_IP[vm-b]} : ${INTRA_IP[vm-a]} }
NFT"
	sleep 1
	ctrl "G 只按来源地址认人的服务（内网 8080）：把 vm-b 当成了 vm-a 的地址" "${INTRA_IP[vm-a]}" "$(get vm-b "http://$INTRANET_IP:8080/" | field client)"
	check "G 按声明认人的服务：声明里是 vm-b 的地址、来源是 vm-a 的地址，拒绝" 403 "$(code vm-b "http://$INTRANET_IP:$VERIFIED/")"
	check "G 令牌限定了来源的服务：vm-b 的令牌从 vm-a 的地址发来，不认" wrong-source "$(get vm-b "http://$INTRANET_IP/" | field identity)"
	push_mappings >/dev/null
	sleep 1
	check "G 映射恢复之后 vm-b 照常" "vm-b ${INTRA_IP[vm-b]}" "$(get vm-b "http://$INTRANET_IP:$VERIFIED/" | jq -r '"\(.declared) \(.declared_ip)"' 2>/dev/null)"
fi

if want L; then
	say "L 规模和开销"
	PATH_L="vm-farm egress-1 egress-2 gw-1 gw-2 vpn-server intranet-svc"
	for spec in "2 10.2.0.1" "3 10.3.0.1"; do
		set -- $spec
		run_load "cred/声明/块$1/全部身份" vm-farm 65 "$PATH_L" --target "$INTRANET_IP:$VERIFIED_FAST" --src-base "$2" --src-count "$FARM_PER_BLOCK" --conns 128 --threads 3
		check "L 块 $1 的身份逐个经声明访问：被拒绝或失败的个数" 0 "$(fj "$LAST_LOAD" .errors)"
		echo "  覆盖的身份：$(fj "$LAST_LOAD" "if .opened >= $FARM_PER_BLOCK then \"全部 $FARM_PER_BLOCK 个\" else \"\(.opened) 个\" end")"
	done
	for eg in "${EGRESS_NODES[@]}"; do
		echo "  $eg 的凭证代理：$(on "$eg" "curl -s -m 2 http://127.0.0.1:9191/version" | jq -r '"表 \(.entries) 条，查了 \(.lookups) 次，签了 \(.signed) 份声明"')，占内存 $(on "$eg" "ps -o rss= -p \$(systemctl show -p MainPID --value cred-agent.service) | awk '{printf \"%d MB\", \$1 / 1024}'")"
	done
	on intranet-svc "grep -c . /var/log/verifier.log 2>/dev/null | sed 's/^/  校验代理日志行数：/'" || true
	# 每个请求多一次本机查询的开销：同一个七层端口、同样的固定速率，先在按身份查的配置下量，再换回原来的配置量一次
	run_load "cred/开销/按身份查/固定速率" vm-farm 30 "$PATH_L" --target "$INTRANET_IP:$FAST_HTTP_L7" --src-base 10.2.0.1 --src-count "$FARM_PER_BLOCK" --expect-base 100.66.0.1 --conns 128 --threads 3 --rate 500
	with_fixed=$LAST_LOAD
	check "L 按身份查、固定每秒 500 个请求：失败数和身份不符数" "0 0" "$(fj "$LAST_LOAD" '"\(.errors) \(.err_mismatch)"')"
	run_load "cred/开销/按身份查/不限速" vm-farm 30 "$PATH_L" --target "$INTRANET_IP:$FAST_HTTP_L7" --src-base 10.2.0.1 --src-count "$FARM_PER_BLOCK" --expect-base 100.66.0.1 --conns 128 --threads 3
	with_max=$LAST_LOAD
	trap - EXIT
	restore
	run_load "cred/开销/不查/固定速率" vm-farm 30 "$PATH_L" --target "$INTRANET_IP:$FAST_HTTP_L7" --src-base 10.2.0.1 --src-count "$FARM_PER_BLOCK" --expect-base 100.66.0.1 --conns 128 --threads 3 --rate 500
	echo "  固定每秒 500 个请求时的延迟（p50 / p99，毫秒）：按身份查 $(fj "$with_fixed" '"\(.p50_ms) / \(.p99_ms)"')，不查 $(fj "$LAST_LOAD" '"\(.p50_ms) / \(.p99_ms)"')"
	run_load "cred/开销/不查/不限速" vm-farm 30 "$PATH_L" --target "$INTRANET_IP:$FAST_HTTP_L7" --src-base 10.2.0.1 --src-count "$FARM_PER_BLOCK" --expect-base 100.66.0.1 --conns 128 --threads 3
	echo "  不限速时每秒的请求数：按身份查 $(fj "$with_max" .rps)，不查 $(fj "$LAST_LOAD" .rps)"
else
	trap - EXIT
	restore
fi

say "收尾检查：原来的配置下三台虚拟机照常"
for vm in "${VMS[@]}"; do
	r=$(get "$vm" "http://$INTRANET_IP/")
	check "$vm 的来源和凭证" "${INTRA_IP[$vm]} $vm" "$(echo "$r" | field client) $(echo "$r" | field identity)"
done
check "vm-a 用逐台的客户端证书访问 9443" vm-a "$(get vm-a "http://$INTRANET_IP:9443/" | field client_cert)"
finish
