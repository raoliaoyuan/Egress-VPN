#!/usr/bin/env bash
# 把 nodes.json 的改动增量地应用到 EVE 上已有的实验，不打乱画面布局：
# 已有的节点和网络保留它们在网页里的位置，文本对象原样保留；新增的节点和网络用 nodes.json 里的位置。
# 用法：lab/eve-ng/lab-sync.sh [--dry-run]
#
# 做的事：
#   1. 写入新的实验文件（内容有变化时），改之前的那份备份在 EVE 主机的构建目录里；
#   2. 对每个节点比较“期望的”和“实际的”：
#      - 硬件（核数、内存、每块网卡接到哪个网络）：EVE 只在启动节点时读这些参数，在运行的节点和期望不一致就要停掉重启；
#      - 节点表：节点开机时按磁盘里的 /opt/lab/nodes.json 配置主机名和地址。镜像里的那份是构建镜像时的，
#        新增的节点、改了名字或换了网段的节点都要换成新的。在运行的节点经 SSH 更新；
#        没在运行或登录不上的节点，停掉后直接改它的磁盘（新节点先建好磁盘）。镜像本身不动，其他节点不受影响；
#   3. 调用 lab-up.sh 启动没在运行的节点，等它们都能登录。
# 只停第 2 步列出的节点，不碰 EVE 上的其他实验。可以重复执行，没有差别时什么都不做。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$LAB_DIR"
DRY=${1:-}
BUILD=/home/$EVE_USER/egressvpn-build
IMG=/opt/unetlab/addons/qemu/$(jq -r .lab.image nodes.json)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

say "1/3 实验文件"
eve "cat $LAB_FILE" > "$TMP/old.unl"
python3 make-lab.py --merge "$TMP/old.unl" > "$TMP/new.unl"
labid=$(sed -n 's/.*<lab [^>]* id="\([^"]*\)".*/\1/p' "$TMP/new.unl")
RUN=/opt/unetlab/tmp/0/$labid
if cmp -s "$TMP/old.unl" "$TMP/new.unl"; then
	echo "没有变化"
elif [ "$DRY" = --dry-run ]; then
	echo "有变化（预演，不写入）"
else
	bak=$BUILD/Egress-VPN.unl.before-sync-$(date +%Y%m%d-%H%M%S)
	eve "mkdir -p $BUILD && sudo -n cp -p $LAB_FILE $bak && cat > /tmp/Egress-VPN.unl" < "$TMP/new.unl"
	eve "sudo -n install -o www-data -g www-data -m 644 /tmp/Egress-VPN.unl $LAB_FILE && rm -f /tmp/Egress-VPN.unl"
	echo "已写入 $LAB_FILE，原文件备份在 EVE 主机的 $bak"
fi

say "2/3 逐个节点比较期望和实际"
jq --arg p "$MGMT_PREFIX" '.nodes |= map(.mgmt = "\($p).\(.mgmt_host)")' nodes.json > "$TMP/nodes.json"
want_hash=$(sha256sum < "$TMP/nodes.json" | cut -c1-16)
# 实际状态：每个在运行的节点一行“编号 核数 内存 网卡0接的网桥,网卡1接的网桥,…”，以及每个节点磁盘里节点表的版本记号。
eve "for d in $RUN/*/; do id=\$(basename \$d)
	args=\$(ps -eo args | grep \"[q]emu-system.* -uuid \" | grep -- \"-netdev tap,id=net0,ifname=vunl0_\${id}_0,\" | head -1)
	mark=\$(sudo -n cat \$d/.lab-nodes 2>/dev/null || echo -)
	if [ -n \"\$args\" ]; then
		smp=\$(echo \"\$args\" | sed -n 's/.* -smp \([0-9]*\).*/\1/p'); mem=\$(echo \"\$args\" | sed -n 's/.* -m \([0-9]*\).*/\1/p')
		br=; i=0; while [ -e /sys/class/net/vunl0_\${id}_\$i ]; do br=\$br\$(basename \$(readlink /sys/class/net/vunl0_\${id}_\$i/master 2>/dev/null) 2>/dev/null),; i=\$((i+1)); done
		echo \"\$id running \$smp \$mem \$br \$mark\"
	else echo \"\$id stopped - - - \$mark\"; fi
done" < /dev/null > "$TMP/actual"
python3 - "$TMP/new.unl" "$TMP/actual" "$want_hash" > "$TMP/plan" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
nets = {n.get("id"): (n.get("type") if n.get("type").startswith("pnet") else "vnet0_" + n.get("id")) for n in root.iter("network")}
actual = {}
for line in open(sys.argv[2]):
    f = line.split()
    if len(f) == 6:
        actual[f[0]] = f[1:]
for e in root.iter("node"):
    nid = e.get("id")
    want = (e.get("cpu"), e.get("ram"), "".join(nets[i.get("network_id")] + "," for i in e.iter("interface")))
    state, smp, mem, br, mark = actual.get(nid, ["absent", "-", "-", "-", "-"])
    hw = "ok" if state != "running" or (smp, mem, br) == want else "stale"
    print(nid, e.get("name"), state, hw, "ok" if mark == sys.argv[3] else "old")
PY
declare -a STOP=() SEED=() PUSH=()
while read -r id name state hw nodes; do
	if [ "$state" = running ] && [ "$hw" = stale ]; then STOP+=("$id:$name"); echo "  $name：硬件和期望不一致，要重启"; fi
	if [ "$nodes" = old ]; then
		if [ "$state" = running ]; then PUSH+=("$id:$name"); else SEED+=("$id:$name"); fi
	fi
done < "$TMP/plan"
[ "$DRY" = --dry-run ] && { echo "  要更新节点表的：${PUSH[*]:-无} ${SEED[*]:-}"; exit 0; }

eve "mkdir -p $BUILD && cat > $BUILD/nodes.json" < "$TMP/nodes.json"
for item in "${PUSH[@]:-}"; do
	[ -n "$item" ] || continue
	id=${item%%:*}; name=${item#*:}
	host=$(jq -r --argjson id "$id" '.nodes[] | select(.id == $id) | .mgmt_host' nodes.json)
	if $SSH_NODE "lab@$MGMT_PREFIX.$host" "sudo tee /opt/lab/nodes.json >/dev/null && sync" < "$TMP/nodes.json" 2>/dev/null; then
		eve "echo $want_hash | sudo -n tee $RUN/$id/.lab-nodes >/dev/null" < /dev/null
		echo "  $name：节点表已经 SSH 更新"
	else
		# 登录不上：多半是磁盘里的节点表不认识这个节点，开机后没配上地址。停掉，下面直接改磁盘。
		STOP+=("$id:$name"); SEED+=("$id:$name"); echo "  $name：登录不上，停掉后直接改磁盘"
	fi
done
for item in $(printf '%s\n' "${STOP[@]:-}" | sort -u); do
	id=${item%%:*}; name=${item#*:}
	eve "sudo -n /opt/unetlab/wrappers/unl_wrapper -a stop -T 0 -D $id -F $LAB_FILE" < /dev/null >/dev/null 2>&1 || true
	echo "  已停止 $name"
done
for item in "${SEED[@]:-}"; do
	[ -n "$item" ] || continue
	id=${item%%:*}; name=${item#*:}; dir=$RUN/$id
	eve "sudo -n mkdir -p $dir
sudo -n test -e $dir/hda.qcow2 || sudo -n /opt/qemu/bin/qemu-img create -b $IMG/hda.qcow2 -f qcow2 $dir/hda.qcow2 >/dev/null
sudo -n virt-customize -q -a $dir/hda.qcow2 --upload $BUILD/nodes.json:/opt/lab/nodes.json 2>&1 | grep -v 'random seed\|^guest\$' || true
echo $want_hash | sudo -n tee $dir/.lab-nodes >/dev/null
sudo -n chown root:unl $dir $dir/hda.qcow2 $dir/.lab-nodes; sudo -n chmod 2775 $dir" < /dev/null
	echo "  $name：节点表已写进磁盘"
done
[ ${#STOP[@]} -eq 0 ] && [ ${#SEED[@]} -eq 0 ] && [ ${#PUSH[@]} -eq 0 ] && echo "  没有差别"

say "3/3 启动节点"
exec "$LAB_DIR/lab-up.sh"
