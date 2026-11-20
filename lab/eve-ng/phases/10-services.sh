#!/usr/bin/env bash
# 阶段 1：两个回显服务。intranet-svc 提供 HTTP（80）和 HTTPS（8443），public-web 提供 HTTP（80）。
# 同时生成实验用的 CA 和内网服务证书，以及 Egress 要注入的凭证。这些都只存在于 state/ 目录，不进版本库。
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
if [ ! -s "$STATE/credential" ]; then
	(umask 077; printf 'lab-credential-%s\n' "$(openssl rand -hex 12)" > "$STATE/credential")
	echo "已生成凭证（只存在 state/credential 和 Egress 上）"
fi

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
put intranet-svc "$STATE/tls/svc.key" /etc/lab/svc.key
unit "intranet-svc /etc/lab/svc.pem /etc/lab/svc.key" > "$STATE/echo.unit"
put intranet-svc "$STATE/echo.unit" /etc/systemd/system/echo.service
on intranet-svc "chmod 600 /etc/lab/svc.key; systemctl daemon-reload; systemctl enable -q --now echo.service; systemctl restart echo.service; sleep 1; systemctl is-active echo.service"

say "public-web"
put public-web "$FILES/echo-server.py" /opt/lab/echo-server.py
unit "public-web" > "$STATE/echo.unit"
put public-web "$STATE/echo.unit" /etc/systemd/system/echo.service
on public-web "systemctl daemon-reload; systemctl enable -q --now echo.service; systemctl restart echo.service; sleep 1; systemctl is-active echo.service"
rm -f "$STATE/echo.unit"

say "自检"
check "intranet-svc 本机访问 HTTP" intranet-svc "$(on intranet-svc "curl -s -m 5 http://127.0.0.1/" | field server)"
check "intranet-svc 本机访问 HTTPS" true "$(on intranet-svc "curl -sk -m 5 https://127.0.0.1:8443/" | field tls)"
check "public-web 本机访问 HTTP" public-web "$(on public-web "curl -s -m 5 http://127.0.0.1/" | field server)"
finish
