#!/usr/bin/env bash
# 阶段 6：主备切换。先把还在旧方式上的虚拟机都迁移过来，然后：
#   1. 在 vm-a 上持续访问内网服务的同时，给主用网关 gw-1 断电（EVE 停止节点），看 gw-2 多久接管；
#   2. 重新启动 gw-1，确认它回来后是备用，不抢回主用；
#   3. 在 gw-2 上正常停掉 keepalived，把主用平稳切回 gw-1。
set -euo pipefail
. "$(dirname "$0")/common.sh"

has() { on "$1" "$2 >/dev/null 2>&1 && echo 有 || echo 无"; }
vip() { has "$1" "ip -4 addr show | grep -q '$GATEWAY_VIP/'"; }
tun() { has "$1" "ip link show wg0"; }
endpoint() { on vpn-server "wg show wg0 endpoints | grep '$(wgpub gateway)' | awk '{print \$2}' | cut -d: -f1"; }
node_power() { # stop|start 节点编号
	eve "sudo -n /opt/unetlab/wrappers/unl_wrapper -a $1 -T 0 -D $2 -F $LAB_FILE" >/dev/null 2>&1
}
probe_start() { # 秒数：vm-a 每 0.2 秒访问一次内网服务，记下时间和结果
	on vm-a "nohup bash -c 'end=\$((SECONDS+$1)); while [ \$SECONDS -lt \$end ]; do t=\$(date +%s.%N); c=\$(curl -s -m 1 -o /dev/null -w \"%{http_code}\" http://$INTRANET_IP/); echo \"\$t \$c\"; sleep 0.2; done' > /tmp/ha.log 2>&1 &"
}
probe_report() { # 说明：等探测结束后统计中断
	on vm-a "while pgrep -f 'curl -s -m 1' >/dev/null || pgrep -f 'SECONDS' >/dev/null; do sleep 1; done; cat /tmp/ha.log" | python3 -c '
import sys
rows = [l.split() for l in sys.stdin if len(l.split()) == 2]
ok = [float(t) for t, c in rows if c == "200"]
bad = [float(t) for t, c in rows if c != "200"]
if not bad:
    print(f"  {len(rows)} 次探测全部成功，没有观察到中断")
else:
    before = max(t for t in ok if t < bad[0])
    after = min((t for t in ok if t > bad[-1]), default=None)
    if after is None:
        print(f"  {len(rows)} 次探测，从第一次失败起没有再恢复")
    else:
        print(f"  {len(rows)} 次探测，失败 {len(bad)} 次；从最后一次成功到恢复后第一次成功相隔 {after - before:.1f} 秒")
'
}

say "准备：全部虚拟机走新方案，gw-1 主用、gw-2 备用"
for vm in $(cat "$STATE/legacy"); do "$(dirname "$0")/40-migrate.sh" "$vm" >/dev/null; echo "已迁移 $vm"; done
push_mappings >/dev/null
check "gw-1 持有服务地址和隧道" "有 有" "$(vip gw-1) $(tun gw-1)"
check "gw-2 没有服务地址和隧道" "无 无" "$(vip gw-2) $(tun gw-2)"
for vm in vm-a vm-b vm-c; do
	check "$vm 经 gw-1 访问内网的来源" "${INTRA_IP[$vm]}" "$(get "$vm" "http://$INTRANET_IP/" | field client)"
done

say "1 给主用网关 gw-1 断电"
probe_start 35
sleep 8
node_power stop 25
echo "gw-1 已断电（EVE 停止节点 25）"
probe_report
check "gw-2 接管了服务地址和隧道" "有 有" "$(vip gw-2) $(tun gw-2)"
check "vpn-server 看到网关改从 gw-2 接入，服务器配置没有改动" 203.0.113.12 "$(endpoint)"
for vm in vm-a vm-b vm-c; do
	r=$(get "$vm" "http://$INTRANET_IP/")
	check "$vm 经 gw-2 访问内网的来源不变" "${INTRA_IP[$vm]}" "$(echo "$r" | field client)"
	check "$vm 的凭证照常注入" 已注入 "$(echo "$r" | cred)"
done

say "2 重新启动 gw-1"
node_power start 25
for _ in $(seq 1 40); do
	[ "$($SSH_NODE "lab@$(node_ip gw-1)" hostname 2>/dev/null)" = gw-1 ] && break
	sleep 3
done
sleep 8
check "gw-1 回来后是备用，不抢服务地址和隧道" "无 无" "$(vip gw-1) $(tun gw-1)"
check "gw-2 仍是主用" "有 有" "$(vip gw-2) $(tun gw-2)"
check "gw-1 开机后自动加载了映射表" 3 "$(on gw-1 "nft list map ip vpngw vm2intra | grep -oE '[0-9]+(\.[0-9]+){3} : [0-9]+(\.[0-9]+){3}' | wc -l")"

say "3 在 gw-2 上正常停掉 keepalived，把主用切回 gw-1"
probe_start 25
sleep 6
on gw-2 "systemctl stop keepalived"
probe_report
check "gw-1 重新成为主用" "有 有" "$(vip gw-1) $(tun gw-1)"
check "gw-2 让出了服务地址和隧道" "无 无" "$(vip gw-2) $(tun gw-2)"
check "vpn-server 看到网关改回从 gw-1 接入" 203.0.113.11 "$(endpoint)"
on gw-2 "systemctl start keepalived"
sleep 4
check "gw-2 的 keepalived 恢复后保持备用" "无 无" "$(vip gw-2) $(tun gw-2)"
check "vm-a 切回后访问内网的来源不变" 100.64.0.7 "$(get vm-a "http://$INTRANET_IP/" | field client)"
finish
