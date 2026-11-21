#!/usr/bin/env bash
# 阶段 1：实验里的服务。
# intranet-svc 上有两个：回显服务提供 HTTP（80、8080、8081）、HTTPS（8443）和要求客户端证书的 HTTPS（9443）；
# 一个要登录的非 HTTP 服务（Redis 协议的最小实现）提供明文加口令（6379）和要求客户端证书的 TLS（6380）。
# public-web 上只有回显服务的 HTTP（80、8080、8081）。
# 同时生成实验用的 CA、内网服务证书，以及三类凭证：
#   令牌：每台虚拟机在每个服务上一个；客户端证书：每台虚拟机一张；
#   静态凭证：内网服务上所有虚拟机共用的一个账号和口令，以及每台虚拟机登录非 HTTP 服务用的口令。
# 这些都只存在于 state/ 目录，不进版本库。服务端只拿到摘要。
set -euo pipefail
. "$(dirname "$0")/common.sh"

say "实验用的 CA、内网服务证书和凭证"
mkdir -p "$STATE/tls"
if [ ! -s "$STATE/tls/ca.pem" ]; then
	(cd "$STATE/tls" && umask 077 \
		&& openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 365 \
			-keyout ca.key -out ca.pem -subj "/CN=Egress-VPN lab CA" 2>/dev/null \
		&& openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
			-keyout svc.key -out svc.csr -subj "/CN=intranet-svc" 2>/dev/null \
		&& printf 'subjectAltName=DNS:intranet-svc,IP:%s\n' "$INTRANET_IP" > svc.ext \
		&& openssl x509 -req -in svc.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 365 \
			-extfile svc.ext -out svc.pem 2>/dev/null)
	echo "已生成 CA 和内网服务证书"
else
	echo "沿用已有的 CA 和证书"
fi
if [ ! -s "$STATE/tls/client-ca.pem" ]; then
	(cd "$STATE/tls" && umask 077 \
		&& openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 365 \
			-keyout client-ca.key -out client-ca.pem -subj "/CN=Egress-VPN lab client CA" 2>/dev/null \
		&& printf 'extendedKeyUsage=clientAuth\n' > client.ext \
		&& for vm in "${VMS[@]}"; do
			openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
				-keyout "client-$vm.key" -out "client-$vm.csr" -subj "/CN=$vm" 2>/dev/null \
			&& openssl x509 -req -in "client-$vm.csr" -CA client-ca.pem -CAkey client-ca.key -CAcreateserial -days 365 \
				-extfile client.ext -out "client-$vm.pem" 2>/dev/null || exit 1
		done)
	echo "已生成客户端 CA 和每台虚拟机的客户端证书"
else
	echo "沿用已有的客户端证书"
fi
mkdir -p "$STATE/creds"; chmod 700 "$STATE/creds"
rm -f "$STATE/credential"   # 早先所有虚拟机共用的那一个凭证，不再使用
for svc in intranet-svc public-web; do
	for vm in "${VMS[@]}"; do
		[ -s "$STATE/creds/$vm.$svc.token" ] || (umask 077; printf 'lab-token-%s\n' "$(openssl rand -hex 12)" > "$STATE/creds/$vm.$svc.token")
	done
done
for vm in "${VMS[@]}"; do
	printf '%s %s\n' "$(tr -d '\n' < "$STATE/creds/$vm.public-web.token" | sha256sum | cut -d' ' -f1)" "$vm"
	[ -s "$STATE/creds/$vm.intranet-svc.pass" ] || (umask 077; printf 'lab-static-%s\n' "$(openssl rand -hex 12)" > "$STATE/creds/$vm.intranet-svc.pass")
done > "$STATE/creds/public-web.hashes"
[ -s "$STATE/creds/intranet-svc.shared" ] || (umask 077; printf '%s:lab-static-%s\n' "$SHARED_USER" "$(openssl rand -hex 12)" > "$STATE/creds/intranet-svc.shared")
echo "令牌 $(ls "$STATE/creds"/*.token | wc -l) 个，非 HTTP 服务的口令 $(ls "$STATE/creds"/*.pass | wc -l) 个，共用账号 1 个；服务端只拿到摘要"

unit() { # 程序 启动参数
	cat <<EOF
[Unit]
Description=Lab $1
After=lab-init.service

[Service]
ExecStart=/usr/bin/python3 /opt/lab/$1 $2
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
}

say "intranet-svc"
put intranet-svc "$FILES/echo-server.py" /opt/lab/echo-server.py
put intranet-svc "$STATE/tls/svc.pem" /etc/lab/svc.pem
put_secret intranet-svc "$STATE/tls/svc.key" /etc/lab/svc.key
put intranet-svc "$STATE/tls/client-ca.pem" /etc/lab/client-ca.pem
put intranet-svc "$FILES/resp-server.py" /opt/lab/resp-server.py
svc_table bound
tls_args="--cert /etc/lab/svc.pem --key /etc/lab/svc.key --client-ca /etc/lab/client-ca.pem"
unit echo-server.py "intranet-svc $tls_args --tokens /etc/lab/tokens" > "$STATE/echo.unit"
put intranet-svc "$STATE/echo.unit" /etc/systemd/system/echo.service
unit resp-server.py "intranet-svc $tls_args --tokens /etc/lab/tokens" > "$STATE/echo.unit"
put intranet-svc "$STATE/echo.unit" /etc/systemd/system/resp.service
on intranet-svc "systemctl daemon-reload; systemctl enable -q --now echo.service resp.service; systemctl restart echo.service resp.service; sleep 1; systemctl is-active echo.service resp.service | tr '\n' ' '; echo"

say "public-web"
put public-web "$FILES/echo-server.py" /opt/lab/echo-server.py
put public-web "$STATE/creds/public-web.hashes" /etc/lab/tokens
unit echo-server.py "public-web --tokens /etc/lab/tokens" > "$STATE/echo.unit"
put public-web "$STATE/echo.unit" /etc/systemd/system/echo.service
on public-web "systemctl daemon-reload; systemctl enable -q --now echo.service; systemctl restart echo.service; sleep 1; systemctl is-active echo.service"
rm -f "$STATE/echo.unit"

say "自检"
check "intranet-svc 本机访问 HTTP" intranet-svc "$(on intranet-svc "curl -s -m 5 http://127.0.0.1/" | field server)"
check "intranet-svc 本机访问 HTTPS" true "$(on intranet-svc "curl -sk -m 5 https://127.0.0.1:8443/" | field tls)"
check "intranet-svc 的 9443 端口，不带客户端证书" 握手被拒绝 "$(on intranet-svc "curl -sk -m 5 -o /dev/null https://127.0.0.1:9443/ && echo 连通 || echo 握手被拒绝")"
check "intranet-svc 没带凭证的请求，认出的身份" 无 "$(on intranet-svc "curl -s -m 5 http://127.0.0.1/" | field identity)"
check "intranet-svc 的非 HTTP 服务，没登录就发命令" "-NOAUTH Authentication required." "$(on intranet-svc "exec 3<>/dev/tcp/127.0.0.1/6379; printf 'PING\r\n' >&3; head -1 <&3 | tr -d '\r'")"
check "intranet-svc 的非 HTTP 服务在监听的端口" "6379 6380" "$(on intranet-svc "ss -ltn | grep -oE ':63(79|80) ' | tr -d ': ' | sort -u | tr '\n' ' '" | sed 's/ $//')"
check "intranet-svc 的非 HTTP 服务，6380 端口不带客户端证书发 PING，收到的应答行数" 0 "$(on intranet-svc "(printf 'PING\r\n'; sleep 1) | timeout 5 openssl s_client -quiet -connect 127.0.0.1:6380 2>/dev/null | grep -c . || true")"
check "public-web 本机访问 HTTP" public-web "$(on public-web "curl -s -m 5 http://127.0.0.1/" | field server)"
finish
