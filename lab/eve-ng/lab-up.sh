#!/usr/bin/env bash
# 把实验放到 EVE 上并启动全部节点，等它们都能登录。可以重复执行：
# 实验文件不存在时创建，已存在时不覆盖（加 --recreate 才覆盖，且要求没有节点在运行）；只启动还没运行的节点。
# 用法：lab/eve-ng/lab-up.sh [--recreate]
# 只启动东西，不停止、不重启任何节点，也不碰 EVE 上的其他实验。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$LAB_DIR"

say "1/3 实验文件"
exists=$(eve "[ -f $LAB_FILE ] && echo yes || echo no")
if [ "$exists" = no ] || [ "${1:-}" = --recreate ]; then
	python3 make-lab.py | eve "cat > /tmp/Egress-VPN.unl"
	eve "sudo -n install -o www-data -g www-data -m 644 /tmp/Egress-VPN.unl $LAB_FILE && rm -f /tmp/Egress-VPN.unl"
	echo "已写入 $LAB_FILE"
else
	echo "$LAB_FILE 已存在，沿用"
fi

say "2/3 启动节点"
# 在 EVE 主机上用 EVE 自己的代码查状态、用 unl_wrapper 启动节点，不登录网页接口。
eve php <<'PHP' || die "节点检查或启动失败"
<?php
require_once('/opt/unetlab/html/includes/init.php');
$file = '/opt/unetlab/labs/Egress-VPN.unl';
function nodes($file) {
    $st = [];
    foreach ((new Lab($file, 0))->getNodes() as $id => $n) $st[$id] = [$n->getName(), $n->getStatus()];
    ksort($st);
    return $st;
}
foreach (nodes($file) as $id => [$name, $status]) {
    if ($status == 2) continue;
    echo "启动节点 $id $name\n";
    $out = [];
    exec('sudo -n /opt/unetlab/wrappers/unl_wrapper -a start -T 0 -D ' . $id . ' -F ' . escapeshellarg($file) . ' 2>&1', $out, $rc);
    if ($rc !== 0) {
        echo implode("\n", $out), "\n节点 $id 启动失败（unl_wrapper 返回 $rc）\n";
        exit(1);
    }
    sleep(2);
}
$bad = false;
foreach (nodes($file) as $id => [$name, $status]) {
    echo "节点 $id $name status=$status\n";
    $bad = $bad || $status != 2;
}
exit($bad ? 1 : 0);
PHP

say "3/3 等节点可以登录"
left=$(node_names)
for _ in $(seq 1 60); do
	still=""
	for n in $left; do
		if [ "$($SSH_NODE "lab@$(node_ip "$n")" hostname 2>/dev/null)" = "$n" ]; then
			echo "$n $(node_ip "$n")：可登录"
		else
			still="$still $n"
		fi
	done
	left=$still
	[ -z "$left" ] && break
	sleep 3
done
[ -z "$left" ] || die "这些节点 3 分钟内没有就绪：$left"
echo "全部节点就绪"
