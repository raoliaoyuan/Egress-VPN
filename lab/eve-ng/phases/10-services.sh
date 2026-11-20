#!/usr/bin/env bash
# 阶段 1：两个回显服务。intranet-svc 提供 HTTP（80、8080）、HTTPS（8443）和要求客户端证书的 HTTPS（9443），
# public-web 提供 HTTP（80、8080）。
# 同时生成实验用的 CA、内网服务证书，以及凭证：每台虚拟机在每个服务上一个令牌，每台虚拟机一张客户端证书。
# 这些都只存在于 state/ 目录，不进版本库。令牌和客户端私钥之后只部署到 Egress，服务端只拿到令牌的摘要。
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
		printf '%s %s\n' "$(tr -d '\n' < "$STATE/creds/$vm.$svc.token" | sha256sum | cut -d' ' -f1)" "$vm"
	done > "$STATE/creds/$svc.hashes"
done
echo "令牌：每台虚拟机在每个服务上一个，共 $(ls "$STATE/creds"/*.token | wc -l) 个；服务端只拿到摘要"

unit() { # 服务名 启动参数
	cat <<EOF
[Unit]
Description=Lab echo service
After=lab-init.service

[Service]
ExecStart=/usr/bin/python3 /opt/lab/echo-server.py $1
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
put intranet-svc "$STATE/creds/intranet-svc.hashes" /etc/lab/tokens
unit "intranet-svc --cert /etc/lab/svc.pem --key /etc/lab/svc.key --client-ca /etc/lab/client-ca.pem --tokens /etc/lab/tokens" > "$STATE/echo.unit"
put intranet-svc "$STATE/echo.unit" /etc/systemd/system/echo.service
on intranet-svc "systemctl daemon-reload; systemctl enable -q --now echo.service; systemctl restart echo.service; sleep 1; systemctl is-active echo.service"

say "public-web"
put public-web "$FILES/echo-server.py" /opt/lab/echo-server.py
put public-web "$STATE/creds/public-web.hashes" /etc/lab/tokens
unit "public-web --tokens /etc/lab/tokens" > "$STATE/echo.unit"
put public-web "$STATE/echo.unit" /etc/systemd/system/echo.service
on public-web "systemctl daemon-reload; systemctl enable -q --now echo.service; systemctl restart echo.service; sleep 1; systemctl is-active echo.service"
rm -f "$STATE/echo.unit"

say "自检"
check "intranet-svc 本机访问 HTTP" intranet-svc "$(on intranet-svc "curl -s -m 5 http://127.0.0.1/" | field server)"
check "intranet-svc 本机访问 HTTPS" true "$(on intranet-svc "curl -sk -m 5 https://127.0.0.1:8443/" | field tls)"
check "intranet-svc 的 9443 端口，不带客户端证书" 握手被拒绝 "$(on intranet-svc "curl -sk -m 5 -o /dev/null https://127.0.0.1:9443/ && echo 连通 || echo 握手被拒绝")"
check "intranet-svc 没带凭证的请求，认出的身份" 无 "$(on intranet-svc "curl -s -m 5 http://127.0.0.1/" | field identity)"
check "public-web 本机访问 HTTP" public-web "$(on public-web "curl -s -m 5 http://127.0.0.1/" | field server)"
finish
