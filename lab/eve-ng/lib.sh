# 实验脚本的公共部分。用法：在脚本开头 `. "$(dirname "$0")/lib.sh"`。
# 环境相关的地址写在 local.env（不进版本库，参照 local.env.example）：
# EVE 主机用免密 SSH 登录，可以经一台跳板机；实验节点经管理网用实验专用密钥直连。
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_FILE=/opt/unetlab/labs/Egress-VPN.unl
LAB_KEY="$LAB_DIR/state/lab_ed25519"
SSH_NODE="ssh -i $LAB_KEY -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

say() { printf '\n== %s\n' "$*"; }
die() { printf '失败：%s\n' "$*" >&2; exit 1; }

[ -f "$LAB_DIR/local.env" ] || die "缺少 $LAB_DIR/local.env，请参照 local.env.example 填写"
. "$LAB_DIR/local.env"
: "${EVE_HOST:?local.env 里没有 EVE_HOST}" "${MGMT_PREFIX:?local.env 里没有 MGMT_PREFIX}"
EVE_USER=${EVE_USER:-eve}

# eve "<命令>"：在 EVE 主机上执行一条 shell 命令。标准输入会传过去，所以也用来上传文件和喂脚本：
#   eve "cat > /tmp/x" < 本地文件        eve php <<'PHP' … PHP
eve() {
	if [ -n "${EVE_JUMP:-}" ]; then
		ssh -o BatchMode=yes "$EVE_JUMP" "ssh -o ConnectTimeout=8 -o BatchMode=yes $EVE_USER@$EVE_HOST $(printf '%q' "$1")"
	else
		ssh -o ConnectTimeout=8 -o BatchMode=yes "$EVE_USER@$EVE_HOST" "$1"
	fi
}

# node_ip <节点名>：节点的管理网地址（管理网前缀加上节点表里的 mgmt_host）。
node_ip() { jq -r --arg n "$1" --arg p "$MGMT_PREFIX" '.nodes[] | select(.name == $n) | "\($p).\(.mgmt_host)"' "$LAB_DIR/nodes.json"; }
node_names() { jq -r '.nodes[].name' "$LAB_DIR/nodes.json"; }

# on <节点名> "<命令>"：在节点上以 root 执行一段 shell。命令从标准输入送过去，引号不需要再转义。
on() {
	local ip; ip=$(node_ip "$1"); [ -n "$ip" ] || die "节点表里没有 $1"
	printf '%s\n' "$2" | $SSH_NODE "lab@$ip" sudo bash -s
}

# put <节点名> <本地文件> <节点上的路径>：把文件放到节点上（root 所有）。
put() {
	local ip; ip=$(node_ip "$1")
	$SSH_NODE "lab@$ip" "sudo mkdir -p $(dirname "$3") && sudo tee $3 >/dev/null" < "$2"
}
