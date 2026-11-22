#!/bin/bash
# 实验节点的内核参数，每次开机时执行（由各节点的 boot.sh 调用）。
# 用法：tune.sh [conntrack]。Egress 和 VPN 网关带 conntrack 参数，其余节点不带。
#
# 多核节点上把收包分摊到各个核（RPS）：实验节点的网卡只有一个队列，不开的话收包的软中断都压在一个核上。
cpus=$(nproc)
if [ "$cpus" -gt 1 ]; then
	mask=$(printf '%x' $(( (1 << cpus) - 1 )))
	for q in /sys/class/net/ens*/queues/rx-*/rps_cpus; do echo "$mask" > "$q" 2>/dev/null; done
fi
sysctl -qw net.core.somaxconn=8192 net.ipv4.tcp_max_syn_backlog=8192 net.core.netdev_max_backlog=10000
# 关闭后的套接字（TIME_WAIT）最多留多少个。默认值按内存算，小内存节点只有四千个。
sysctl -qw net.ipv4.tcp_max_tw_buckets=262144
[ "${1:-}" = conntrack ] || exit 0

# 连接跟踪表：系统默认的上限按内存算，1 GB 内存的节点只有 8192 条。一条 TCP 连接正常关闭后，
# 它的记录还要留 120 秒（TIME_WAIT），所以默认值下每秒只能持续新建约 68 条连接，超过就丢新连接的包，
# 连管理口的 SSH 也一起进不来。这里把上限提到“每 2 KB 内存一条、最多一百万条”，TIME_WAIT 的保留时间降到 30 秒。
modprobe nf_conntrack 2>/dev/null
max=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 2 ))
[ "$max" -gt 1048576 ] && max=1048576
echo $((max / 4)) > /sys/module/nf_conntrack/parameters/hashsize
sysctl -qw net.netfilter.nf_conntrack_max=$max
sysctl -qw net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
# 本机发起连接时可用的源端口。数据面 A 里，一台 Egress 到一个网关单元的所有连接，
# 源地址、目的地址、目的端口都相同，只有源端口不同，默认的两万八千个端口在建连速率高时不够用。
sysctl -qw net.ipv4.ip_local_reserved_ports=15000-15099
sysctl -qw net.ipv4.ip_local_port_range="10000 65535"
sysctl -qw net.ipv4.tcp_tw_reuse=1
exit 0
