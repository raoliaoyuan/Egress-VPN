#!/bin/bash
# keepalived 的状态通知：当上主用时启动隧道，其余情况停掉隧道。
# 主备共用一对 WireGuard 密钥，同一时刻只能有一台持有隧道。
case "$3" in
MASTER) systemctl start wg-quick@wg0 ;;
*) systemctl stop wg-quick@wg0 ;;
esac
logger -t lab-gw "keepalived 状态 $3，隧道 $(ip link show wg0 >/dev/null 2>&1 && echo 已启动 || echo 已停止)"
