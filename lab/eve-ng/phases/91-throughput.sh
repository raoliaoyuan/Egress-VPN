#!/usr/bin/env bash
# 阶段 9.1：吞吐专项。块 3 的身份从 vm-farm 到内网服务的 TCP 吞吐，走 Egress 的四层转发，每种压法重复几次。
# 用法：91-throughput.sh <标签> [重复次数，默认 3]
#   块 3 现在走哪种数据面、哪几台网关在承载，测的就是那种情况；标签自己起，写进结果里用来区分。
#   B_ONLY=gw-2 91-throughput.sh …  先把数据面 B 收窄到只剩这一台网关承载（测单台网关的上限），测完恢复三台。
#   注意：2026-11-21 这种情况跑了两次，两次都在几分钟后把实验主机（EVE 那台虚拟机）卡死了，原因不明，
#   其余情况没有出过事。除非是专门查这个问题，不要用 B_ONLY。见 docs/ha-scale-results.md 第 9 节。
# 和 90-bench.sh 里那几项吞吐的差别：iperf3 一个进程只用一个核，多条流放在一个进程里时它自己会先到顶。
# 这里“8 条流”是 4 对进程（4 个身份、4 个服务端口）各 2 条流，数据面 B 下它们也更容易均匀地分到各台网关上。
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/bench-lib.sh"
. "$(dirname "$0")/scale-lib.sh"
tag=${1:?用法：91-throughput.sh <标签> [重复次数]}
reps=${2:-3}
NODES="vm-farm rtr-acc egress-2 gw-1 gw-2 gw-3 vpn-server intranet-svc"

b_hops() { on egress-2 "ip route show 10.200.0.0/16 | grep -o 'via 10.1.255.1[123]' | wc -l"; }
if [ -n "${B_ONLY:-}" ]; then
	b_on || die "B_ONLY 只在块 3 走数据面 B 时有意义"
	for gw in "${ALL_GATEWAYS[@]}"; do
		[ "$gw" = "$B_ONLY" ] || on "$gw" "systemctl stop gwb-health.service wg-quick@wgb.service"
	done
	for _ in $(seq 1 20); do [ "$(b_hops)" = 1 ] && break; sleep 1; done
	echo "数据面 B 现在只由 $B_ONLY 承载（Egress 上去内网的下一跳 $(b_hops) 个）"
	restore() {
		for gw in "${ALL_GATEWAYS[@]}"; do on "$gw" "systemctl start wg-quick@wgb.service gwb-health.service" || true; done
		for _ in $(seq 1 60); do [ "$(b_hops)" = 3 ] && [ "$(on vpn-server "ip route show $B_BLOCK_INTRA | grep -c nexthop")" = 3 ] && break; sleep 1; done
		echo "已恢复：Egress 上去内网的下一跳 $(b_hops) 个"
	}
	trap restore EXIT
fi

# multi <标签> <进程数> <每个进程的流数> [-R]：同时跑几对 iperf3，15 秒，吞吐相加。
multi() {
	local label=$1 procs=$2 streams=$3 rev=${4:-} mbps cpu
	on vm-farm "rm -f /tmp/ipf-*.json; for i in \$(seq 1 $procs); do nohup iperf3 -c $INTRANET_IP -p \$((5200 + i)) -B 10.3.0.\$((4 + i)) -t 15 -P $streams $rev -J > /tmp/ipf-\$i.json 2>/dev/null < /dev/null & done"
	sleep 3
	# shellcheck disable=SC2086
	cpu_snap "$RESULTS/cpu.a" $NODES
	sleep 8
	# shellcheck disable=SC2086
	cpu_snap "$RESULTS/cpu.b" $NODES
	mbps=$(on vm-farm "while pgrep -x iperf3 >/dev/null; do sleep 1; done; cat /tmp/ipf-*.json | jq -s '[.[].end.sum_received.bits_per_second // 0] | add / 1e6 | floor'")
	cpu=$(cpu_diff "$RESULTS/cpu.a" "$RESULTS/cpu.b")
	jq -cn --arg label "$label" --argjson mbps "${mbps:-0}" --argjson cpu "$cpu" '{label: $label, mbps: $mbps, cpu: $cpu}' >> "$RESULTS/throughput.jsonl"
	echo "  $label：${mbps:-0} Mbit/s"
	echo "$cpu" | cpu_line
	sleep 3
}

say "吞吐专项：$tag（每种压法 $reps 次）"
for r in $(seq 1 "$reps"); do
	multi "$tag/上行1流/$r" 1 1
	multi "$tag/下行1流/$r" 1 1 -R
	multi "$tag/上行8流/$r" 4 2
	multi "$tag/下行8流/$r" 4 2 -R
done

say "汇总：$tag（中位数；CPU 是占这个节点全部核的百分比）"
python3 - "$RESULTS/throughput.jsonl" "$tag" <<'PY'
import json, statistics, sys
rows = {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    parts = r["label"].rsplit("/", 2)
    if len(parts) == 3 and parts[0] == sys.argv[2]:
        rows.setdefault(parts[1], []).append(r)
for test, rs in rows.items():
    rs = rs[-int(len(rs)):]
    m = [r["mbps"] for r in rs]
    def c(n): return statistics.median(r["cpu"][n]["busy_pct"] for r in rs if n in r["cpu"])
    print(f"  {test}：{statistics.median(m):.0f} Mbit/s（{min(m)} 到 {max(m)}）；egress-2 {c('egress-2'):.0f}%，"
          f"gw-1 {c('gw-1'):.0f}% gw-2 {c('gw-2'):.0f}% gw-3 {c('gw-3'):.0f}%，vpn-server {c('vpn-server'):.0f}%，"
          f"intranet-svc {c('intranet-svc'):.0f}%，vm-farm {c('vm-farm'):.0f}%，实验主机 {c('实验主机'):.0f}%")
PY
