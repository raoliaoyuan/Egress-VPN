#!/usr/bin/env bash
# 在 EVE 主机上基于 Debian 12 镜像生成实验节点镜像 linux-egressvpn：
# 装好 WireGuard、nftables、keepalived、抓包工具和 Envoy，建一个只能用实验密钥登录的 lab 账户。
# 用法：ENVOY=/path/to/envoy lab/eve-ng/build-image.sh
# 前提：EVE 主机上有 Debian 12 的节点镜像（addons/qemu/linux-debian12）和 virt-customize。
# 镜像是节点磁盘的底层文件，所以实验里有节点在运行时拒绝重建。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$LAB_DIR"
: "${ENVOY:?请用 ENVOY 环境变量指定本机上的 Envoy 可执行文件}"
IMG=/opt/unetlab/addons/qemu/linux-egressvpn
BASE=/opt/unetlab/addons/qemu/linux-debian12/hda.qcow2
BUILD=/home/$EVE_USER/egressvpn-build

running=$(eve php <<'PHP'
<?php
require_once('/opt/unetlab/html/includes/init.php');
$file = '/opt/unetlab/labs/Egress-VPN.unl';
$n = 0;
if (is_file($file)) foreach ((new Lab($file, 0))->getNodes() as $node) if ($node->getStatus() == 2) $n++;
echo $n;
PHP
)
running=$(printf '%s' "$running" | tr -d '[:space:]')
[ "$running" = 0 ] || die "实验里有 $running 个节点在运行，先停掉它们再重建镜像"

say "上传构建材料到 EVE 主机"
eve "mkdir -p $BUILD"
for f in image/lab-init.py image/lab-init.service image/customize.txt image/sshd-lab.conf image/sudoers-lab image/console-autologin.conf; do
	eve "cat > $BUILD/$(basename "$f")" < "$f"
done
# 节点表里只有管理地址的末段，这里补上管理网前缀再放进镜像。
jq --arg p "$MGMT_PREFIX" '.nodes |= map(.mgmt = "\($p).\(.mgmt_host)")' nodes.json | eve "cat > $BUILD/nodes.json"
eve "cat > $BUILD/lab.pub" < state/lab_ed25519.pub
eve "cat > $BUILD/envoy" < "$ENVOY"
eve "cd $BUILD && sha256sum envoy | cut -c1-16 && ls -la"

say "定制镜像（安装软件包需要几分钟）"
eve "cd $BUILD && sudo -n rm -f new.qcow2 \
  && sudo -n cp --sparse=always $BASE new.qcow2 \
  && sudo -n virt-customize -q -a new.qcow2 --commands-from-file customize.txt; rc=\$?
  [ \$rc -eq 0 ] || { sudo -n rm -f new.qcow2; echo '镜像定制失败，原有镜像未动'; exit \$rc; }
  sudo -n mkdir -p $IMG && sudo -n mv new.qcow2 $IMG/hda.qcow2 || exit 1
  sudo -n /opt/unetlab/wrappers/unl_wrapper -a fixpermissions
  sudo -n qemu-img info $IMG/hda.qcow2 | grep -E 'virtual size|disk size'"
echo "镜像 linux-egressvpn 已就绪"
