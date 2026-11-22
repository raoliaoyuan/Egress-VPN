#!/usr/bin/env bash
# 阶段 9：压测。同一套测法，对当前的形态跑一遍；结果的标签里带上形态，几次的结果放在一起比较。
# 用法：90-bench.sh [base|block3]
#   block3（默认）：从 vm-farm 用块 3 的 FARM_PER_BLOCK 个身份发流量。块 3 现在走哪种数据面，测的就是哪种：
#                   执行过 85-dataplane-b.sh 是数据面 B（标签 B/…），否则是数据面 A（标签 A/…）。
#   base：          从 vm-a 一个身份发流量，经网关单元 1，和改造前的基线是同一种测法（标签 base/…）。
# 测的东西：TCP 吞吐（iperf3，单条流和 8 条并行）；固定速率下的延迟和各节点 CPU；最大的新建连接速率；
# 长连接复用时的请求速率；固定速率跑完后各节点上留着的连接数。
# 所有节点在同一台实验主机上，数字只能做相对比较，不是生产容量。
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/bench-lib.sh"
. "$(dirname "$0")/scale-lib.sh"
mode=${1:-block3}
T=$INTRANET_IP
if [ "$mode" = base ]; then
	L=base; NODE=vm-a; ID="--expect-base ${INTRA_IP[vm-a]}"; BIND=""; FEW=$ID
	NODES="vm-a rtr-acc egress-1 gw-1 gw-2 gw-3 vpn-server intranet-svc"; TH=1
else
	b_on && L=B || L=A
	NODE=vm-farm; ID="--src-base 10.3.0.1 --src-count $FARM_PER_BLOCK --expect-base 100.67.0.1"; BIND="-B 10.3.0.5"
	FEW="--src-base 10.3.0.1 --src-count 100 --expect-base 100.67.0.1"
	NODES="vm-farm rtr-acc egress-2 gw-1 gw-2 gw-3 vpn-server intranet-svc"; TH=3
fi
conns() { # 各节点上已建立的 TCP 连接数，排成一行
	local n out=""
	for n in $NODES; do out="$out $n $(on "$n" "ss -Htn state established | wc -l" 2>/dev/null || echo ?)"; done
	echo "$out"
}

say "$L：TCP 吞吐（走 Egress 的四层转发）"
run_iperf "$L/吞吐/上行单流" "$NODE" 15 "$NODES" $BIND
run_iperf "$L/吞吐/下行单流" "$NODE" 15 "$NODES" $BIND -R
run_iperf "$L/吞吐/上行8流" "$NODE" 15 "$NODES" $BIND -P 8
run_iperf "$L/吞吐/下行8流" "$NODE" 15 "$NODES" $BIND -P 8 -R

say "$L：固定速率（每秒 500 个请求，每个请求新建连接）下的延迟和 CPU"
run_load "$L/定速500/七层" "$NODE" 20 "$NODES" --target $T:$FAST_HTTP_L7 $ID --conns 256 --threads $TH --rate 500
c=$(conns); echo "  跑完时各节点上已建立的连接数：$c"; record "$L/定速500/七层/留下的连接" "{\"conns\": \"$c\"}"
run_load "$L/定速500/四层" "$NODE" 20 "$NODES" --target $T:$FAST_HTTP_L4 $ID --conns 256 --threads $TH --rate 500
sleep 12
if [ "$mode" != base ]; then
	run_load "$L/定速500/七层、只有100个身份" "$NODE" 20 "$NODES" --target $T:$FAST_HTTP_L7 $FEW --conns 256 --threads $TH --rate 500
	c=$(conns); echo "  跑完时各节点上已建立的连接数：$c"; record "$L/定速500/七层、只有100个身份/留下的连接" "{\"conns\": \"$c\"}"
	sleep 12
fi

say "$L：最大的新建连接速率（256 条并发，每个请求新建连接）"
run_load "$L/新建连接/七层" "$NODE" 20 "$NODES" --target $T:$FAST_HTTP_L7 $ID --conns 256 --threads $TH
sleep 15
run_load "$L/新建连接/四层" "$NODE" 20 "$NODES" --target $T:$FAST_HTTP_L4 $ID --conns 256 --threads $TH
sleep 15

say "$L：长连接复用时的请求速率（256 条连接一直复用）"
run_load "$L/长连接/七层" "$NODE" 20 "$NODES" --target $T:$FAST_HTTP_L7 $ID --conns 256 --threads $TH --reqs-per-conn 0
run_load "$L/长连接/四层" "$NODE" 20 "$NODES" --target $T:$FAST_HTTP_L4 $ID --conns 256 --threads $TH --reqs-per-conn 0
echo
echo "原始结果追加在 $RESULTS/bench.jsonl"
