# EVE-NG 实验：完整复现

在 EVE-NG 里用九台 Linux 节点、真实的 WireGuard 和 Envoy 复现整个场景：现状（虚拟机自带隧道）、部署新方案、逐台迁移、回退、TLS 和主备切换。

> 实验里的 Egress 是按“透明劫持”假设写的参考实现，不是真实的 Egress。其余组件用的都是仓库 `config/` 下的配置。

## 环境

- EVE-NG 主机要能免密 SSH 登录并免密 `sudo`，可以经一台跳板机。地址写在 `local.env` 里（不进版本库），参照 [local.env.example](local.env.example) 填写。
- 节点的起停在 EVE 主机上用 EVE 自己的代码和 `unl_wrapper` 完成，不登录网页接口。
- 节点镜像 `linux-egressvpn` 基于 EVE 上的 Debian 12 节点镜像（`linux-debian12`）用 `virt-customize` 定制。
- 每个节点的最后一块网卡接管理网（`pnet0`），操作机要能直连这个网段。

实验文件是 `/opt/unetlab/labs/Egress-VPN.unl`。节点和网络的编号从 21 起，避开同一台 EVE 上其他实验已经占用的小编号：EVE 的网卡名、网桥名和控制台端口只由租户号和编号决定，不同实验用了相同编号就不能同时运行。

## 节点

| 节点 | 编号 | 角色 | 业务地址 | 管理地址末段 |
|---|---|---|---|---|
| `vm-a` | 21 | 业务虚拟机 | `10.1.2.3`，内网 IP `100.64.0.7` | 81 |
| `vm-b` | 22 | 业务虚拟机 | `10.1.2.4`，内网 IP `100.64.0.8` | 82 |
| `vm-c` | 23 | 业务虚拟机 | `10.1.2.99`，内网 IP `100.64.0.99` | 83 |
| `egress` | 24 | 透明劫持、注入凭证，兼作虚拟机的网关 | `10.1.2.1`、`10.1.255.20`、`203.0.113.20` | 84 |
| `gw-1` | 25 | VPN 网关（主） | `10.1.255.11`、`203.0.113.11` | 85 |
| `gw-2` | 26 | VPN 网关（备） | `10.1.255.12`、`203.0.113.12` | 86 |
| `vpn-server` | 27 | WireGuard 服务端 | `203.0.113.1`、`10.200.5.1` | 87 |
| `intranet-svc` | 28 | 内网服务，回显来源地址和凭证头 | `10.200.5.6` | 88 |
| `public-web` | 29 | 模拟公网站点 | `203.0.113.80` | 89 |

网关的服务地址是 `10.1.255.10`，跟着主用网关走。节点的管理地址是 `local.env` 里的管理网前缀加上表中的末段。节点表的原始数据在 [nodes.json](nodes.json)。

## 登录

- SSH：`ssh -i lab/eve-ng/state/lab_ed25519 lab@<管理网前缀>.81`（末段换成对应节点的）。`lab` 账户可以免口令 `sudo`，只接受这把实验专用密钥，不开口令登录。
- 控制台：在 EVE 网页里点节点，或 `telnet <EVE 主机> <32768 + 节点编号>`，直接以 `lab` 登录。

`state/` 目录保存实验专用的 SSH 密钥、WireGuard 密钥、证书和凭证，`local.env` 保存环境地址，两者都不进版本库。删掉 `state/` 就要重建镜像并重新部署。

## 从头搭建

```bash
cp lab/eve-ng/local.env.example lab/eve-ng/local.env   # 然后按自己的环境填写
ssh-keygen -t ed25519 -N '' -f lab/eve-ng/state/lab_ed25519   # 实验专用的登录密钥，先建好 state/ 目录
ENVOY=/path/to/envoy lab/eve-ng/build-image.sh   # 构建节点镜像，需要本机有 Envoy 可执行文件
lab/eve-ng/lab-up.sh                             # 创建实验、启动节点、等待可登录
lab/eve-ng/phases/10-services.sh                 # 回显服务、证书、凭证
lab/eve-ng/phases/20-baseline.sh                 # 现状：每台虚拟机自带隧道
lab/eve-ng/phases/21-check-baseline.sh
lab/eve-ng/phases/30-deploy-solution.sh          # 部署新方案，不迁移虚拟机
lab/eve-ng/phases/40-migrate.sh vm-a             # 迁移一台
lab/eve-ng/phases/50-verify.sh                   # 逐项验证
lab/eve-ng/phases/60-ha.sh                       # 主备切换
```

EVE 主机关机后再开，先确认它已经启动并能登录，再执行 `lab-up.sh`。它只启动还没运行的节点；各节点上的服务都设了开机自启。

## 结果（2026-11-20）

| 阶段 | 检查 | 结果 |
|---|---|---|
| 现状 | 10 项 | 全部通过 |
| 部署新方案 | 6 项 | 全部通过；部署后虚拟机的行为不变 |
| 逐项验证 | 30 项 | 全部通过 |
| 主备切换 | 23 项 | 22 项通过；1 项因脚本统计记录数的写法有误而报失败，人工核对结果正确，脚本已修正 |

“逐项验证”第一次运行时有 1 项失败：伪造身份的对照实验用了“发送后立即半关闭连接”的方式，响应回来之前连接就被拆掉了。改成发送后保持连接，再完整重跑一遍，30 项全部通过。

要点：

- **现状复现了问题本身**：虚拟机经自己的隧道访问内网，内网看到各自的内网 IP，请求里没有凭证；Egress 在虚拟机网卡上只抓到 WireGuard 的 UDP，没有任何去往内网服务的 TCP。
- **迁移后内网 IP 不变，凭证注入生效**：`vm-a` 迁移前后，内网服务看到的来源都是 `100.64.0.7`；迁移后请求带上了 Egress 注入的凭证。
- **新旧并存**：`vpn-server` 上每台虚拟机的 `/32` peer 和网关的 `/22` peer 同时存在时，未迁移的虚拟机不受影响。
- **旧密钥失效**：删除 peer 后，虚拟机用旧密钥重新拨号，握手次数为 0。
- **未登记的虚拟机被拦截**，登记后立即可用。
- **TLS**：Egress 向内网服务发起 TLS 时，在网关上抓包找不到凭证；不走 TLS 时，凭证在网关上以明文可见。
- **回退**：回退到旧方式、再次迁移，来源地址始终不变。
- **主备切换**：主用网关断电，从最后一次成功到恢复后第一次成功相隔约 3.9 秒；正常停掉主用的 keepalived，相隔约 1.4 秒。`vpn-server` 的配置在切换中没有改动，对端地址自动从 `203.0.113.11` 变成 `203.0.113.12`。探测间隔 0.2 秒、单次超时 1 秒，这两个数字的误差在 1 秒左右。

## 实验中发现的一个安全要求

**Egress 必须拒绝虚拟机访问网关所在的网段。**

网关无条件信任来自 Egress 的连接和其中的 PROXY 头。如果 Egress 对目的地址不加限制，虚拟机可以向网关的 15001 端口发起连接：这个连接被 Egress 透明劫持后原样转给网关，虚拟机只要在数据开头自带一个伪造的 PROXY 头，就能冒充任意一台已登记的虚拟机。

对照实验（`50-verify.sh` 的 D3 到 D5）：未登记的 `vm-c` 伪造 PROXY 头声称自己是 `vm-a`。Egress 上有拦截规则时没有任何响应；临时去掉这条规则后，内网服务把它当成了 `100.64.0.7`；恢复规则后再次无响应。

实验里的规则在 [files/egress.nft](files/egress.nft) 的 `guard` 链。真实的 Egress 需要有等价的限制。

## 与方案文档的差别

- **主备切换的实现**：文档只写了“主备共用一对密钥，同一时刻只启动一台”。实验用 keepalived 在两台网关之间漂移服务地址，并在当上主用时启动隧道、其余情况停掉隧道（[files/keepalived.conf](files/keepalived.conf)、[files/gateway-notify.sh](files/gateway-notify.sh)）。
- **网关的映射表从空开始**：仓库的 `vpngw.nft` 里带一条示例记录，实验部署时去掉了它，记录全部由脚本登记。
- **网关入口过滤**：实验加了一条规则，15001 端口只接受 Egress 的地址（[files/gateway-filter.nft](files/gateway-filter.nft)）。文档里把这一点写成了要求，仓库没有给出配置。

## 没有覆盖的内容

- 真实的 Egress，以及它使用的 Envoy 版本。
- 性能和容量。
- 多个 Egress 实例、多个网关单元。
- UDP 等非 TCP 流量进内网，内网主动访问虚拟机。

## 停止和清理

实验目前保持运行。停掉全部节点（在 EVE 主机上执行，编号 21 到 29）：

```bash
for id in $(seq 21 29); do sudo /opt/unetlab/wrappers/unl_wrapper -a stop -T 0 -D $id -F /opt/unetlab/labs/Egress-VPN.unl; done
```

彻底删除实验还需要删掉 `/opt/unetlab/labs/Egress-VPN.unl`、镜像目录 `/opt/unetlab/addons/qemu/linux-egressvpn` 和登录用户主目录下的构建目录 `egressvpn-build`。停止和删除的这几条命令没有实际执行过。
