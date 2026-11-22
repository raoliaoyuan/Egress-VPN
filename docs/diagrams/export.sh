#!/usr/bin/env bash
# 把本目录的 .drawio 源图导出成 ../images/ha/ 下的 PNG，文档引用的是这些 PNG。
# 需要 draw.io 桌面版自带的命令行。不带参数时导出全部，也可以只给某几张：
#   docs/diagrams/export.sh                      # 全部
#   docs/diagrams/export.sh 05-dataplane-a.drawio
# 可执行文件不叫 drawio 时用 DRAWIO 指定，例如 macOS：
#   DRAWIO=/Applications/draw.io.app/Contents/MacOS/draw.io docs/diagrams/export.sh
# 在容器里或以 root 运行时要加 DRAWIO_FLAGS=--no-sandbox。
set -euo pipefail
cd "$(dirname "$0")"
out=../images/ha
mkdir -p "$out"
[ $# -gt 0 ] || set -- *.drawio
for f in "$@"; do
	# 放大两倍保证清晰；留 12 像素边距；-e 把源图嵌进 PNG，所以 PNG 本身也能用 draw.io 打开修改。
	"${DRAWIO:-drawio}" ${DRAWIO_FLAGS:-} -x -f png -s 2 -b 12 -e -o "$out/$(basename "${f%.drawio}").png" "$f"
done
