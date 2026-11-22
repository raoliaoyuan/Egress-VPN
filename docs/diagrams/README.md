# 逻辑图的源文件

[高可用与规模化方案](../ha-scale-design.md)里的十三张逻辑图。每张图有两个文件：

| 文件 | 用途 |
| --- | --- |
| `docs/diagrams/<名字>.drawio` | 源图，用 draw.io 打开修改 |
| `docs/images/ha/<名字>.png` | 文档里显示的图，由源图导出 |

文档引用的是 PNG，在 GitHub 上和本地的 Markdown 预览里都能直接显示。

## 修改一张图

1. 用 [draw.io 桌面版](https://www.drawio.com/)或网页版（app.diagrams.net）打开 `.drawio` 文件，改完保存。
2. 重新导出 PNG：
   - 装了桌面版的话，在仓库根目录执行 `docs/diagrams/export.sh 05-dataplane-a.drawio`；不带参数时导出全部。
   - 或者在 draw.io 里选“文件 → 导出为 → PNG”，缩放填 200%，边框宽度填 12，勾上“包含我的图表副本”，保存到 `docs/images/ha/` 下的同名文件。

导出的 PNG 里嵌着一份源图，所以 PNG 本身也可以直接拖进 draw.io 修改。两处都改过的话，以 `.drawio` 文件为准。

## 图的约定

- 源图是未压缩的 XML，方便看差异。
- 分组（虚线框）是 draw.io 的容器，拖动它时里面的元素一起移动。
- 颜色：蓝色是 Egress，绿色是 VPN 网关，紫色是 VPN 服务器，橙色是控制面，灰色是虚拟机、网络和内网，红色是故障或拒绝，黄色是说明文字。`12-lab-topology` 例外，它用蓝色表示已有的节点、绿色表示新增的节点。

## 清单

| 图 | 内容 |
| --- | --- |
| `01-current-spof` | 现状：九个节点和其中的单点 |
| `02-target-architecture` | 目标架构：逐层去掉单点 |
| `03-block-model` | 地址块：调度和故障的最小单位 |
| `04-access-failover` | 接入分片和 Egress 故障接管 |
| `05-dataplane-a` | 数据面 A：PROXY 协议加四层网关 |
| `06-dataplane-b` | 数据面 B：地址转换搬到 Egress，网关只转发 |
| `07-gateway-failure` | 一台网关故障时，两种数据面的差别 |
| `08-vpn-server-ha` | VPN 服务器多台同时工作 |
| `09-internet-egress` | 互联网出口：两种出口模式和 Egress 上的检查 |
| `10-control-plane` | 控制面：一份权威数据，各节点自己拉取 |
| `11-credential-scale` | 凭证：从逐台生成过滤链，到按身份查 |
| `12-lab-topology` | 实验环境的目标拓扑：十七个节点 |
| `13-roadmap` | 实验改造的六期 |
