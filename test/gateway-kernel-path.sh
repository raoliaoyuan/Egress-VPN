#!/usr/bin/env bash
# 模拟验证 VPN 网关的内核路径：源地址映射、回程包交回本机进程、未登记虚拟机被拒绝。
#
# 用法：bash test/gateway-kernel-path.sh
# 不需要 root，全部在临时的网络命名空间里进行，结束后自动清理，不影响本机网络。
#
# 覆盖范围：
#   - config/vpn-gateway/vpngw.nft 的规则
#   - config/vpn-gateway/wg0.conf 里的路由和策略路由（在脚本里按相同内容手工执行）
# 不覆盖：
#   - WireGuard 本身（用一对 veth 代替隧道，网关侧接口同样命名为 wg0）
#   - Envoy（用一个 Python 进程模拟 original_src 的行为：绑定虚拟机地址并打标记 123）
#   - Egress

set -euo pipefail

if [ "${IN_TEST_NS:-}" != 1 ]; then
	exec env IN_TEST_NS=1 unshare -rn bash "$0" "$@"
fi
cd "$(dirname "$0")/.."

# 对端命名空间：模拟"VPN 服务器 + 内网服务"。
unshare -n sleep 120 &
PEER=$!
trap 'kill "$PEER" 2>/dev/null || true' EXIT
sleep 0.3
in_peer() { nsenter -t "$PEER" -n "$@"; }

# 网关侧：与 wg0.conf 相同的地址、路由、策略路由。
ip link set lo up
ip link add wg0 type veth peer name peer0
ip link set peer0 netns "$PEER"
ip addr add 100.64.0.1/32 dev wg0
ip link set wg0 up
ip route add 10.200.0.0/16 dev wg0
ip rule add iif wg0 fwmark 123 lookup 100
ip route add local 0.0.0.0/0 dev lo table 100
nft -f config/vpn-gateway/vpngw.nft

# 对端：内网服务 10.200.5.6，回程按地址块路由到网关。
in_peer ip link set lo up
in_peer ip addr add 10.200.5.6/16 dev peer0
in_peer ip link set peer0 up
in_peer ip route add 100.64.0.1 dev peer0
in_peer ip route add 100.64.0.0/22 via 100.64.0.1

# 内网服务：把看到的对端地址原样回给客户端。
in_peer python3 -c '
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("10.200.5.6", 8443))
s.listen()
while True:
    c, a = s.accept()
    c.sendall(a[0].encode())
    c.close()
' &
SERVER=$!
trap 'kill "$SERVER" "$PEER" 2>/dev/null || true' EXIT
sleep 0.5

# 模拟网关 Envoy：以虚拟机真实 IP 为源地址、带标记 123 发起连接，返回内网服务看到的来源。
connect_as() {
	python3 -c '
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_IP, 19, 1)                    # IP_TRANSPARENT
s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, 123)
s.bind((sys.argv[1], 0))
s.settimeout(3)
try:
    s.connect(("10.200.5.6", 8443))
    print(s.recv(64).decode())
except OSError as e:
    print("连接失败:", e)
' "$1"
}

fail=0

seen=$(connect_as 10.1.2.3)
if [ "$seen" = "100.64.0.7" ]; then
	echo "通过：已登记的虚拟机 10.1.2.3，内网看到的来源是 $seen，回程数据已收到"
else
	echo "失败：已登记的虚拟机 10.1.2.3，期望内网看到 100.64.0.7，实际：$seen"
	fail=1
fi

seen=$(connect_as 10.1.2.99)
if [[ "$seen" == 连接失败* ]]; then
	echo "通过：未登记的虚拟机 10.1.2.99 无法进入隧道（$seen）"
else
	echo "失败：未登记的虚拟机 10.1.2.99 不应连通，实际内网看到：$seen"
	fail=1
fi

nft add element ip vpngw vm2intra '{ 10.1.2.99 : 100.64.0.99 }'
seen=$(connect_as 10.1.2.99)
if [ "$seen" = "100.64.0.99" ]; then
	echo "通过：登记后 10.1.2.99 可以连通，内网看到的来源是 $seen"
else
	echo "失败：登记后 10.1.2.99 期望内网看到 100.64.0.99，实际：$seen"
	fail=1
fi

exit "$fail"
