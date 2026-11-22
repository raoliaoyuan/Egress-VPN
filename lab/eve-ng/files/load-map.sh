#!/bin/bash
# 用法：load-map.sh <表名>
# 把 /etc/lab/vm2intra（地址分配表，每行“虚拟机真实 IP 内网 IP”）整表换进 nftables 的映射表 vm2intra。
# 清空和重新填入写在同一个文件里，nft -f 把它当成一个事务提交：中间没有“表是空的”那一刻，
# 文件有错时整个事务不生效，原来的表不变。
set -e
table=$1
out=/run/vm2intra.$table.nft
{
	echo "flush map ip $table vm2intra"
	awk -v t="$table" 'NF == 2 { printf "%s%s : %s", (n++ ? ",\n" : "add element ip " t " vm2intra {\n"), $1, $2 } END { if (n) print "\n}" }' /etc/lab/vm2intra
} > "$out"
nft -f "$out"
