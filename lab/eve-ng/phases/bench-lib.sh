# 压测和故障注入的公共部分：`. "$(dirname "$0")/bench-lib.sh"`（在 common.sh 之后）。
# 结果除了打印，还追加到 state/results/ 下的文件里（不进版本库），每行一个 JSON。
RESULTS="$STATE/results"
mkdir -p "$RESULTS"
LAB_BIN="$STATE/bin"          # 本机编译出来的压测工具
FAST_HTTP_L7=8090             # labsrv 的 HTTP 端口，Egress 对它做七层处理
FAST_HTTP_L4=8091             # labsrv 的 HTTP 端口，Egress 对它只做四层转发
ECHO_PORT=7000                # labsrv 的原样回显端口，测长连接用
IPERF_PORT=5201

# build_tools：在本机把 labsrv、labload 编译成静态可执行文件。需要 cc 和静态的 C 库。
build_tools() {
	mkdir -p "$LAB_BIN"
	local t
	for t in labsrv labload; do
		if [ ! -x "$LAB_BIN/$t" ] || [ "$FILES/$t.c" -nt "$LAB_BIN/$t" ]; then
			cc -O2 -Wall -static -pthread -o "$LAB_BIN/$t" "$FILES/$t.c" 2> "$LAB_BIN/$t.log" || { cat "$LAB_BIN/$t.log"; die "编译 $t 失败"; }
		fi
	done
}

# apt_install <节点> <软件包...>：节点上没有就装。实验节点不能直接上网，
# 这里把本机的 HTTP 代理（环境变量 http_proxy）经 SSH 反向隧道借给节点用；本机没有代理时要求节点自己能上网。
apt_install() {
	local node=$1 ip miss proxy hp; shift
	ip=$(node_ip "$node")
	miss=$($SSH_NODE "lab@$ip" "for p in $*; do dpkg -s \$p >/dev/null 2>&1 || printf '%s ' \$p; done")
	[ -z "$miss" ] && return 0
	proxy=${http_proxy:-${HTTP_PROXY:-}}
	if [ -n "$proxy" ]; then
		hp=${proxy#*://}; hp=${hp%/}
		$SSH_NODE -R "13128:$hp" "lab@$ip" "sudo env http_proxy=http://127.0.0.1:13128 https_proxy=http://127.0.0.1:13128 DEBIAN_FRONTEND=noninteractive \
bash -c 'apt-get -q update >/dev/null 2>&1; apt-get -q install -y --no-install-recommends $miss >/dev/null 2>&1'"
	else
		on "$node" "DEBIAN_FRONTEND=noninteractive apt-get -q update >/dev/null 2>&1; apt-get -q install -y --no-install-recommends $miss >/dev/null 2>&1"
	fi
	miss=$($SSH_NODE "lab@$ip" "for p in $*; do dpkg -s \$p >/dev/null 2>&1 || printf '%s ' \$p; done")
	[ -z "$miss" ] || die "$node 上没能装上：$miss"
	echo "$node 已安装 $*"
}

# install_load_client <节点>：压测客户端、长连接客户端、iperf3。
install_load_client() {
	build_tools
	put "$1" "$LAB_BIN/labload" /usr/local/bin/labload
	put "$1" "$FILES/stream-client.py" /usr/local/bin/stream-client.py
	# 发流量的节点自己也要放宽：只有一个源地址时，默认的源端口范围和 TIME_WAIT 会先把它自己卡住。
	on "$1" "chmod 755 /usr/local/bin/labload /usr/local/bin/stream-client.py
printf 'net.ipv4.ip_local_port_range = 10000 65535\nnet.ipv4.tcp_tw_reuse = 1\n' > /etc/sysctl.d/90-lab-load.conf; sysctl -q -p /etc/sysctl.d/90-lab-load.conf"
	apt_install "$1" iperf3
}

# install_load_server：内网服务节点上的压测服务端（8090、8091 是 HTTP，7000 原样回显）和 iperf3 服务端。
install_load_server() {
	build_tools
	apt_install intranet-svc iperf3
	on intranet-svc "systemctl stop labsrv.service 2>/dev/null; true"
	put intranet-svc "$LAB_BIN/labsrv" /usr/local/bin/labsrv
	cat > "$STATE/unit.tmp" <<EOF
[Unit]
Description=Lab load-test server
After=lab-init.service

[Service]
ExecStart=/bin/sh -c 'exec /usr/local/bin/labsrv --threads \$(nproc) --http $FAST_HTTP_L7 --http $FAST_HTTP_L4 --echo $ECHO_PORT'
Restart=always
RestartSec=1
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
	put intranet-svc "$STATE/unit.tmp" /etc/systemd/system/labsrv.service
	cat > "$STATE/unit.tmp" <<EOF
[Unit]
Description=Lab iperf3 server
After=lab-init.service

[Service]
ExecStart=/usr/bin/iperf3 -s -p $IPERF_PORT
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
	put intranet-svc "$STATE/unit.tmp" /etc/systemd/system/iperf3-lab.service
	# iperf3 一个进程只用一个核。吞吐专项（91-throughput.sh）同时跑几对进程，另外三个服务端在 5202 到 5204。
	sed -e 's/Lab iperf3 server/Lab iperf3 server on port %i/' -e "s/-p $IPERF_PORT/-p %i/" "$STATE/unit.tmp" > "$STATE/unit2.tmp"
	put intranet-svc "$STATE/unit2.tmp" /etc/systemd/system/iperf3-lab@.service
	rm -f "$STATE/unit.tmp" "$STATE/unit2.tmp"
	on intranet-svc "chmod 755 /usr/local/bin/labsrv; systemctl daemon-reload; systemctl disable -q --now iperf3.service 2>/dev/null
systemctl enable -q --now iperf3-lab@5202.service iperf3-lab@5203.service iperf3-lab@5204.service
systemctl enable -q labsrv.service iperf3-lab.service; systemctl restart labsrv.service iperf3-lab.service; sleep 1
echo \"intranet-svc：labsrv \$(systemctl is-active labsrv.service)，iperf3 \$(systemctl is-active iperf3-lab.service)\""
}

# ---------- CPU ----------
# cpu_snap <文件> <节点...>：记下各节点和实验主机此刻的 CPU 计数（/proc/stat 第一行）。各节点并行取。
cpu_snap() {
	local f=$1 n; shift
	rm -f "$f".*
	for n in "$@"; do
		( echo "$n $($SSH_NODE "lab@$(node_ip "$n")" 'echo $(nproc) $(head -1 /proc/stat)' 2>/dev/null)" > "$f.$n" ) &
	done
	( echo "实验主机 $(eve 'echo $(nproc) $(head -1 /proc/stat)' 2>/dev/null)" > "$f.host" ) &
	wait
	cat "$f".* > "$f"; rm -f "$f".*
}
# cpu_diff <前> <后>：输出一个 JSON 对象，每个节点是“忙的比例（占它全部核的百分比）/ 其中软中断 / 核数”。
cpu_diff() {
	python3 - "$1" "$2" <<'PY'
import json, sys
def load(p):
    d = {}
    for line in open(p):
        f = line.split()
        if len(f) >= 11:
            d[f[0]] = (int(f[1]), [int(x) for x in f[3:11]])
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
out = {}
for n in a:
    if n not in b:
        continue
    d = [y - x for x, y in zip(a[n][1], b[n][1])]
    total = sum(d) or 1
    busy = total - d[3] - d[4]
    out[n] = {"cpus": a[n][0], "busy_pct": round(100 * busy / total, 1), "softirq_pct": round(100 * d[6] / total, 1),
              "steal_pct": round(100 * d[7] / total, 1)}
print(json.dumps(out, ensure_ascii=False))
PY
}
cpu_line() { # 把 cpu_diff 的 JSON 排成一行字
	python3 -c '
import json, sys
d = json.load(sys.stdin)
print("  CPU：" + "，".join("%s %.0f%%×%d核" % (n, v["busy_pct"], v["cpus"]) for n, v in d.items()))'
}

# ---------- 压测 ----------
# run_load <标签> <发流量的节点> <秒数> "<要看 CPU 的节点>" <labload 的参数...>
# 在节点上后台跑 labload，中间一段取各节点的 CPU，结束后取回结果。结果（加上标签和 CPU）追加到 state/results/bench.jsonl。
run_load() {
	local label=$1 node=$2 secs=$3 cpu_nodes=$4; shift 4
	on "$node" "rm -f /tmp/load.json; nohup /usr/local/bin/labload --duration $secs $* > /tmp/load.json 2> /tmp/load.err < /dev/null &"
	sleep 2
	# shellcheck disable=SC2086
	cpu_snap "$RESULTS/cpu.a" $cpu_nodes
	sleep $((secs > 8 ? secs - 6 : 1))
	# shellcheck disable=SC2086
	cpu_snap "$RESULTS/cpu.b" $cpu_nodes
	local out="" cpu
	for _ in $(seq 1 30); do
		out=$(on "$node" "pgrep -x labload >/dev/null || cat /tmp/load.json" 2>/dev/null) && [ -n "$out" ] && break
		sleep 1
	done
	[ -n "$out" ] || { echo "  $label：没有取到结果：$(on "$node" 'cat /tmp/load.err' 2>/dev/null)"; return 1; }
	cpu=$(cpu_diff "$RESULTS/cpu.a" "$RESULTS/cpu.b")
	echo "$out" | jq -c --arg label "$label" --argjson cpu "$cpu" '{label: $label} + . + {cpu: $cpu}' >> "$RESULTS/bench.jsonl"
	echo "$out" | jq -r --arg label "$label" '"  \($label)：成功 \(.ok)，失败 \(.errors)（其中身份不符 \(.err_mismatch)），每秒 \(.rps) 个请求、\(.conn_per_s) 条新连接；延迟 p50 \(.p50_ms) / p99 \(.p99_ms) 毫秒"'
	echo "$cpu" | cpu_line
	LAST_LOAD=$out
}

# run_iperf <标签> <发流量的节点> <秒数> "<要看 CPU 的节点>" <iperf3 的额外参数...>：TCP 吞吐，走 Egress 的四层转发。
run_iperf() {
	local label=$1 node=$2 secs=$3 cpu_nodes=$4; shift 4
	on "$node" "rm -f /tmp/iperf.json; nohup iperf3 -c $INTRANET_IP -p $IPERF_PORT -t $secs -J $* > /tmp/iperf.json 2>/dev/null < /dev/null &"
	sleep 2
	# shellcheck disable=SC2086
	cpu_snap "$RESULTS/cpu.a" $cpu_nodes
	sleep $((secs > 8 ? secs - 6 : 1))
	# shellcheck disable=SC2086
	cpu_snap "$RESULTS/cpu.b" $cpu_nodes
	local out="" cpu mbps
	for _ in $(seq 1 30); do
		out=$(on "$node" "pgrep -x iperf3 >/dev/null || cat /tmp/iperf.json" 2>/dev/null) && [ -n "$out" ] && break
		sleep 1
	done
	mbps=$(echo "$out" | jq -r '(.end.sum_received.bits_per_second // 0) / 1e6 | floor' 2>/dev/null || echo 0)
	cpu=$(cpu_diff "$RESULTS/cpu.a" "$RESULTS/cpu.b")
	jq -cn --arg label "$label" --argjson mbps "${mbps:-0}" --argjson cpu "$cpu" \
		--argjson retr "$(echo "$out" | jq '.end.sum_sent.retransmits // 0' 2>/dev/null || echo 0)" \
		'{label: $label, mbps: $mbps, retransmits: $retr, cpu: $cpu}' >> "$RESULTS/bench.jsonl"
	echo "  $label：${mbps:-0} Mbit/s"
	echo "$cpu" | cpu_line
	LAST_MBPS=${mbps:-0}
}

# ---------- 后台的压测和长连接（故障注入时同时跑几路）----------
# load_bg <节点> <标记> <labload 的参数...>：后台跑 labload，带时间线。
load_bg() {
	local node=$1 tag=$2; shift 2
	on "$node" "rm -f /tmp/load-$tag.json /tmp/tl-$tag.txt; nohup /usr/local/bin/labload $* --timeline /tmp/tl-$tag.txt > /tmp/load-$tag.json 2>/dev/null < /dev/null &"
}
# load_wait <节点> <标记>：等它结束，输出结果的 JSON，时间线存到 state/results/tl-<标记>.txt。
load_wait() {
	local out="" i
	for i in $(seq 1 120); do
		out=$(on "$1" "pgrep -f 'timeline /tmp/tl-$2.txt' >/dev/null || cat /tmp/load-$2.json" 2>/dev/null) && [ -n "$out" ] && break
		sleep 1
	done
	on "$1" "cat /tmp/tl-$2.txt" > "$RESULTS/tl-$2.txt" 2>/dev/null || true
	echo "${out:-{\}}"
}
# stream_bg <节点> <标记> <stream-client.py 的参数...>：后台开一组持续传输的长连接。
stream_bg() {
	local node=$1 tag=$2; shift 2
	on "$node" "rm -f /tmp/stream-$tag.json; nohup python3 /usr/local/bin/stream-client.py $* > /tmp/stream-$tag.json 2>/tmp/stream-$tag.err < /dev/null &"
}
# stream_wait <节点> <标记>：等它结束，输出汇总（不含每条连接的明细），完整结果存到 state/results/stream-<标记>.json。
stream_wait() {
	local i
	for i in $(seq 1 120); do
		on "$1" "pgrep -f 'stream-client.py' >/dev/null" 2>/dev/null || break
		sleep 1
	done
	on "$1" "cat /tmp/stream-$2.json" > "$RESULTS/stream-$2.json" 2>/dev/null || true
	jq -c 'del(.detail)' "$RESULTS/stream-$2.json" 2>/dev/null || echo '{}'
}
record() { # 标签 JSON：追加到 state/results/fault.jsonl
	echo "$2" | jq -c --arg label "$1" '{label: $label} + .' >> "$RESULTS/fault.jsonl" 2>/dev/null || true
}

# ---------- 故障注入 ----------
node_id() { jq -r --arg n "$1" '.nodes[] | select(.name == $n) | .id' "$LAB_DIR/nodes.json"; }
# node_power <stop|start> <节点名>：用 EVE 停止（等于断电）或启动一个节点。
node_power() {
	eve "sudo -n /opt/unetlab/wrappers/unl_wrapper -a $1 -T 0 -D $(node_id "$2") -F $LAB_FILE" >/dev/null 2>&1
}
wait_node() { # 节点名：等它能登录
	local i
	for i in $(seq 1 60); do
		[ "$($SSH_NODE "lab@$(node_ip "$1")" hostname 2>/dev/null)" = "$1" ] && return 0
		sleep 3
	done
	return 1
}
# outage <时间线文件> <故障注入的时刻（Unix 秒）>：从 labload 的时间线算中断。
# 输出一个 JSON：故障之后第一格出现失败的时刻、最后一格有失败的时刻、
# “从故障前最后一格全部成功到恢复后第一格全部成功”的间隔（秒，粒度 0.1），以及失败的请求数。
outage() {
	python3 - "$1" "$2" <<'PY'
import json, sys
rows = [(float(a), int(b), int(c)) for a, b, c in (l.split() for l in open(sys.argv[1]))]
t_fault = float(sys.argv[2])
bad = [t for t, ok, fail in rows if fail > 0 and t >= t_fault - 0.5]
total_fail = sum(fail for t, ok, fail in rows)
total_ok = sum(ok for t, ok, fail in rows)
if not bad:
    print(json.dumps({"failed": total_fail, "ok": total_ok, "outage_s": 0.0}))
    sys.exit()
first, last = bad[0], bad[-1]
before = max((t for t, ok, fail in rows if t < first and ok > 0 and fail == 0), default=None)
after = min((t for t, ok, fail in rows if t > last and ok > 0 and fail == 0), default=None)
print(json.dumps({
    "failed": total_fail, "ok": total_ok,
    "first_fail_after_fault_s": round(first - t_fault, 1),
    "outage_s": round(after - before, 1) if before is not None and after is not None else None,
    "recovered": after is not None,
}))
PY
}
