#!/usr/bin/env bash
# 用真实的 Envoy 模拟验证整条链路：
#   虚拟机 → Egress（Envoy，透明劫持）→ VPN 网关（Envoy + nftables）→ 内网服务
#
# 用法：ENVOY=/path/to/envoy bash test/envoy-chain.sh
# 不需要 root，全部在临时的网络命名空间里进行，结束后自动清理，不影响本机网络。
#
# 覆盖范围：
#   - config/vpn-gateway/envoy.yaml（原样加载）
#   - config/vpn-gateway/vpngw.nft（原样加载）
#   - config/vpn-gateway/wg0.conf 里的路由和策略路由（在脚本里按相同内容手工执行）
#   - config/egress/vpn-gateway-cluster.yaml（原样使用，只把网关域名换成测试地址）
# 不覆盖：
#   - WireGuard 本身（用一对 veth 代替隧道，网关侧接口同样命名为 wg0）
#   - 真实的 Egress：这里的 Egress 是一个参考实现，监听器是按"透明劫持"的假设写的，
#     分别用四层代理（tcp_proxy）和七层代理（HTTP 连接管理器）两种方式接入同一个上游
#   - TLS、主备切换、性能

set -euo pipefail

: "${ENVOY:?请用 ENVOY 环境变量指定 Envoy 可执行文件的路径}"

if [ "${IN_TEST_NS:-}" != 1 ]; then
	exec env IN_TEST_NS=1 unshare -rn bash "$0" "$@"
fi
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
PIDS=()
cleanup() {
	kill "${PIDS[@]}" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

new_ns() { unshare -n sleep 300 & PIDS+=("$!"); echo "$!" >"$WORK/$1.pid"; }
new_ns vm; new_ns egress; new_ns intranet
sleep 0.3
VM=$(cat "$WORK/vm.pid"); EG=$(cat "$WORK/egress.pid"); IN=$(cat "$WORK/intranet.pid")
in_vm() { nsenter -t "$VM" -n "$@"; }
in_eg() { nsenter -t "$EG" -n "$@"; }
in_in() { nsenter -t "$IN" -n "$@"; }

# ---------- 网络 ----------
# 当前命名空间充当 VPN 网关。
ip link set lo up
ip link add wg0 type veth peer name peer0
ip link add to-egress type veth peer name to-gw
ip link add to-vm type veth peer name vm0
ip link set peer0 netns "$IN"
ip link set to-gw netns "$EG"
ip link set to-vm netns "$EG"
ip link set vm0 netns "$VM"

# 网关：与 wg0.conf 相同的地址、路由、策略路由，加上面向 Egress 的地址。
ip addr add 100.64.0.1/32 dev wg0
ip link set wg0 up
ip addr add 10.1.255.10/24 dev to-egress
ip link set to-egress up
ip route add 10.200.0.0/16 dev wg0
ip rule add iif wg0 fwmark 123 lookup 100
ip route add local 0.0.0.0/0 dev lo table 100
nft -f config/vpn-gateway/vpngw.nft

# Egress：一侧接虚拟机，一侧接网关。虚拟机发来的 TCP 全部重定向到本机的 Envoy。
in_eg ip link set lo up
in_eg ip addr add 10.1.2.1/24 dev to-vm
in_eg ip link set to-vm up
in_eg ip addr add 10.1.255.20/24 dev to-gw
in_eg ip link set to-gw up
in_eg nft -f - <<'EOF'
table ip egress {
	chain intercept {
		type nat hook prerouting priority dstnat; policy accept;
		iifname "to-vm" tcp dport 8080 redirect to :15007
		iifname "to-vm" meta l4proto tcp redirect to :15006
	}
}
EOF

# 虚拟机：10.1.2.3 已登记，10.1.2.99 未登记。默认路由指向 Egress。
in_vm ip link set lo up
in_vm ip addr add 10.1.2.3/24 dev vm0
in_vm ip addr add 10.1.2.99/24 dev vm0
in_vm ip link set vm0 up
in_vm ip route add default via 10.1.2.1

# 内网：服务 10.200.5.6，回程按地址块路由到网关。
in_in ip link set lo up
in_in ip addr add 10.200.5.6/16 dev peer0
in_in ip link set peer0 up
in_in ip route add 100.64.0.1 dev peer0
in_in ip route add 100.64.0.0/22 via 100.64.0.1

# ---------- 进程 ----------
# 内网服务：8443 是裸 TCP，8080 是 HTTP。两者都把看到的对端地址回给客户端。
# 后台进程都直接用 nsenter 启动，不经过上面的函数，这样记录到的才是进程自己的 PID，清理时能杀掉。
nsenter -t "$IN" -n python3 -c '
import socket, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.client_address[0].encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

threading.Thread(target=HTTPServer(("10.200.5.6", 8080), H).serve_forever, daemon=True).start()
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("10.200.5.6", 8443))
s.listen()
while True:
    c, a = s.accept()
    c.sendall(a[0].encode())
    c.close()
' &
PIDS+=("$!")

# 参考 Egress 的配置：监听器是测试用的，上游取自仓库里的片段。
python3 - "$WORK/egress.yaml" <<'EOF'
import sys, yaml

clusters = yaml.safe_load(open("config/egress/vpn-gateway-cluster.yaml"))["clusters"]
# 测试环境里没有 DNS，把网关域名换成测试地址。其余内容原样使用。
ep = clusters[0]["load_assignment"]["endpoints"][0]["lb_endpoints"][0]["endpoint"]
ep["address"]["socket_address"]["address"] = "10.1.255.10"

original_dst = {
    "name": "envoy.filters.listener.original_dst",
    "typed_config": {"@type": "type.googleapis.com/envoy.extensions.filters.listener.original_dst.v3.OriginalDst"},
}
tcp = {
    "name": "intercept_tcp",
    "address": {"socket_address": {"address": "0.0.0.0", "port_value": 15006}},
    "listener_filters": [original_dst],
    "filter_chains": [{"filters": [{
        "name": "envoy.filters.network.tcp_proxy",
        "typed_config": {
            "@type": "type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy",
            "stat_prefix": "intercept_tcp",
            "cluster": "vpn_gateway_1",
        },
    }]}],
}
http = {
    "name": "intercept_http",
    "address": {"socket_address": {"address": "0.0.0.0", "port_value": 15007}},
    "listener_filters": [original_dst],
    "filter_chains": [{"filters": [{
        "name": "envoy.filters.network.http_connection_manager",
        "typed_config": {
            "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
            "stat_prefix": "intercept_http",
            "route_config": {"virtual_hosts": [{
                "name": "all", "domains": ["*"],
                "routes": [{"match": {"prefix": "/"}, "route": {"cluster": "vpn_gateway_1"}}],
            }]},
            "http_filters": [{
                "name": "envoy.filters.http.router",
                "typed_config": {"@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"},
            }],
        },
    }]}],
}
yaml.safe_dump({"static_resources": {"listeners": [tcp, http], "clusters": clusters}}, open(sys.argv[1], "w"))
EOF

"$ENVOY" -c config/vpn-gateway/envoy.yaml --disable-hot-restart --concurrency 1 \
	-l warn --log-path "$WORK/gateway.log" &
PIDS+=("$!"); GW_ENVOY=$!
nsenter -t "$EG" -n "$ENVOY" -c "$WORK/egress.yaml" --disable-hot-restart --concurrency 1 \
	-l warn --log-path "$WORK/egress.log" &
PIDS+=("$!"); EG_ENVOY=$!

# 等两个 Envoy 开始监听。
ready() { python3 -c 'import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 1).close()' "$1" "$2" 2>/dev/null; }
for _ in $(seq 50); do
	if in_eg bash -c "$(declare -f ready); ready 10.1.255.10 15001 && ready 127.0.0.1 15006 && ready 127.0.0.1 15007"; then
		break
	fi
	sleep 0.2
done
if ! kill -0 "$GW_ENVOY" 2>/dev/null || ! kill -0 "$EG_ENVOY" 2>/dev/null; then
	echo "Envoy 没有启动成功"; tail -n 20 "$WORK"/*.log; exit 1
fi

# ---------- 测试 ----------
# 虚拟机以指定的真实 IP 访问内网服务，返回内网服务看到的来源地址。
tcp_as() {
	in_vm python3 -c '
import socket, sys
s = socket.socket()
s.bind((sys.argv[1], 0))
s.settimeout(15)
try:
    s.connect(("10.200.5.6", 8443))
    d = s.recv(64).decode()
    print(d if d else "连接被关闭，没有收到数据")
except OSError as e:
    print("连接失败:", e)
' "$1"
}
http_as() {
	in_vm python3 -c '
import http.client, sys
c = http.client.HTTPConnection("10.200.5.6", 8080, timeout=15, source_address=(sys.argv[1], 0))
try:
    c.request("GET", "/")
    r = c.getresponse()
    print(r.read().decode() if r.status == 200 else "HTTP %d" % r.status)
except OSError as e:
    print("连接失败:", e)
' "$1"
}

fail=0
expect() { # 说明 期望值 实际值
	if [ "$3" = "$2" ]; then
		echo "通过：$1，内网看到的来源是 $3"
	else
		echo "失败：$1，期望内网看到 $2，实际：$3"
		fail=1
	fi
}
expect_blocked() { # 说明 实际值
	if [[ "$2" != 100.64.* && "$2" != 10.* ]]; then
		echo "通过：$1（$2）"
	else
		echo "失败：$1，不应连通，实际内网看到：$2"
		fail=1
	fi
}

expect "四层代理，已登记的虚拟机 10.1.2.3" 100.64.0.7 "$(tcp_as 10.1.2.3)"
expect "七层代理，已登记的虚拟机 10.1.2.3" 100.64.0.7 "$(http_as 10.1.2.3)"
expect_blocked "四层代理，未登记的虚拟机 10.1.2.99 被拦截" "$(tcp_as 10.1.2.99)"
expect_blocked "七层代理，未登记的虚拟机 10.1.2.99 被拦截" "$(http_as 10.1.2.99)"

nft add element ip vpngw vm2intra '{ 10.1.2.99 : 100.64.0.99 }'
expect "四层代理，登记后的虚拟机 10.1.2.99" 100.64.0.99 "$(tcp_as 10.1.2.99)"
expect "七层代理，登记后的虚拟机 10.1.2.99" 100.64.0.99 "$(http_as 10.1.2.99)"

# 两台虚拟机交替发起 HTTP 请求：确认 Egress 不会把一台虚拟机的请求
# 放到为另一台虚拟机建立的上游连接上。
mixed=""
for src in 10.1.2.3 10.1.2.99 10.1.2.3 10.1.2.99; do
	mixed+="$(http_as "$src") "
done
expect "七层代理，两台虚拟机交替请求时来源不串" "100.64.0.7 100.64.0.99 100.64.0.7 100.64.0.99 " "$mixed"

if [ "$fail" != 0 ]; then
	echo "---- 网关 Envoy 日志 ----"; tail -n 20 "$WORK/gateway.log" || true
	echo "---- Egress Envoy 日志 ----"; tail -n 20 "$WORK/egress.log" || true
fi
exit "$fail"
