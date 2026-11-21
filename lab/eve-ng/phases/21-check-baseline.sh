#!/usr/bin/env bash
# 检查现状：每台虚拟机经自己的隧道到内网、各有独立的内网 IP；
# 去公网站点的请求带上了 Egress 注入的凭证，去内网的请求没有；Egress 在虚拟机网卡上只能看到隧道的密文。
set -euo pipefail
. "$(dirname "$0")/common.sh"

say "内网看到的来源地址，以及服务能不能从凭证认出调用方"
for vm in vm-a vm-b vm-c; do
	r=$(get "$vm" "http://$INTRANET_IP/")
	check "$vm 访问内网，内网看到的来源" "${INTRA_IP[$vm]}" "$(echo "$r" | field client)"
	check "$vm 访问内网，请求里没有凭证，服务认不出调用方（问题所在）" 无 "$(echo "$r" | field identity)"
done
r=$(get vm-a "http://$PUBLIC_IP/")
check "vm-a 访问公网站点，来源是 Egress" 203.0.113.20 "$(echo "$r" | field client)"
check "vm-a 访问公网站点，站点从凭证认出的调用方" vm-a "$(echo "$r" | field identity)"

say "Egress 在虚拟机网卡上能看到什么"
# vm-a 访问内网期间，在 Egress 面向虚拟机的网卡上抓包 4 秒。
# 先删掉上次的文件：tcpdump 写出的文件属于 tcpdump 用户，系统不允许 root 覆盖 /tmp 下别人的文件，
# 不删的话这次抓包会写不进去，后面读到的就是上次的结果。
on egress '. /etc/lab/ifaces.env; rm -f /tmp/base.pcap; timeout 4 tcpdump -ni $IF_VM_NET -w /tmp/base.pcap "host 10.1.2.3" >/dev/null 2>&1 &'
on vm-a "sleep 1; for i in 1 2 3; do curl -s -m 3 http://$INTRANET_IP/ >/dev/null; done; sleep 3"
counts=$(on egress 'udp=$(tcpdump -nr /tmp/base.pcap "udp port 51820" 2>/dev/null | wc -l)
tcp=$(tcpdump -nr /tmp/base.pcap "tcp and host 10.200.5.6" 2>/dev/null | wc -l)
echo "$udp $tcp"')
udp=${counts% *}; tcp=${counts#* }
check "Egress 看不到任何去往内网服务的 TCP" 0 "$tcp"
if [ "$udp" -gt 0 ]; then echo "通过：Egress 只看到隧道的 UDP 密文（$udp 个包）"; else echo "失败：没有抓到隧道的 UDP 包"; FAILS=$((FAILS + 1)); fi
finish
