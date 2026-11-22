# 和业界做法的对照

2026-11-22

本文把本方案拆成十一个方面，逐个对照服务网格（Istio、Consul）、Envoy、Kubernetes 的出口网关（Cilium、Calico、OpenShift）、跨网络隧道（Submariner、Tailscale）和几种凭证代理产品的做法。方案本身见 [design.md](design.md)，高可用和规模化见 [ha-scale-design.md](ha-scale-design.md)，到内网的通路见 [transport-options.md](transport-options.md)。

> **读之前先看这三条。**
>
> - “业界”一栏依据的是各产品的官方文档和官方仓库，2026-11-22 查阅。**没有搭环境试过其中任何一个产品**，文档没写清楚的地方单独标了“没查到”或“推断”。
> - “本方案”一栏的验证状态沿用各篇文档的说法。实验里的 Egress 是参考实现，真实的 Egress 没有验证过。
> - “这次查到的产品里没有”不等于“业界没有”。查阅的范围见[第 6 节](#6-依据和没查到的)。

## 目录

1. [结论](#1-结论)
2. [总表](#2-总表)
3. [逐项说明](#3-逐项说明)
4. [本方案多做的](#4-本方案多做的)
5. [业界有、本方案没做的](#5-业界有本方案没做的)
6. [依据和没查到的](#6-依据和没查到的)

## 1. 结论

- **要解决的问题业界都遇到过。** “流量先被加密，代理看不到七层”“凭证不放进工作负载”“过了共享代理还要认得出是谁”“工作负载绕过代理”，在服务网格里都有对应的问题和做法。
- **思路一致的有五项：** 把加密挪到代理之后；凭证只放在代理上；用 PROXY protocol 加 `original_src` 传递并还原来源地址；隧道建在网关上而不是工作负载里；代理放在工作负载够不着的地方，并堵住绕过的路。
- **本方案多做的有三项：** 来源地址一对一映射到每台虚拟机，而且是几万台的量级；凭证按虚拟机区分；映射之后的地址是经隧道路由过去的一整块，不是网关自己网卡上的地址。
- **业界有、本方案没做的主要有两项：** 代理之间的身份声明带认证（mTLS）；非 HTTP 协议的凭证代理。
- **2026-11-22 参考业界的做法选定了两个方向，都还没有验证：** 客户端证书改成 Egress 只用自己的一张证书，每个请求带一份短期的身份声明；不走 HTTP 的口令交给内网一侧、数据库前面的接入代理。见[第 5 节](#5-业界有本方案没做的)。下面第 2、3 节的“本方案”一栏写的仍是现在的做法。
- **这次查到的产品里，没有一个同时提供“共享的七层凭证注入、每个工作负载一个固定来源地址、站点到站点隧道”这三样。** 最接近的是 Cilium：1.16 起七层策略和出口网关可以同时作用于同一个工作负载，但它的七层是访问控制，出口地址是网关节点网卡上的地址。

## 2. 总表

“一致程度”分四档：一致、部分一致、本方案多做、业界多做。

| 方面 | 本方案 | 业界的做法 | 一致程度 | 本方案的验证状态 |
| --- | --- | --- | --- | --- |
| 1. 加密的位置 | VPN 客户端移出虚拟机，放到 Egress 之后的网关；到服务的 TLS 由 Egress 发起，虚拟机发明文 | Istio 的 TLS origination：应用发明文，边车或出口网关发起 TLS。Cilium 的 WireGuard、IPsec 由节点建隧道，Pod 里没有配置 | 一致 | 实验已验证 |
| 2. 凭证注入 | 只对指定服务注入（目的地址、端口、Host 都匹配），按虚拟机区分，覆盖虚拟机自带的同名请求头 | Istio 出口网关、Consul terminating gateway 把客户端证书放在网关上。Envoy 有凭证注入和 AWS 签名过滤器。Fly.io 的 Tokenizer 由代理解密后注入 | 一致；按虚拟机区分是本方案多做 | 实验已验证；规模化的做法未验证，其中客户端证书已选定改用身份声明（见第 5 节） |
| 3. 代理之间传递身份 | Egress 在连接开头发 PROXY 头；网关用 `original_src` 以虚拟机地址为源发起连接，靠标记和策略路由收回程 | Envoy 文档的“IP Transparency”列的就是这套做法。Istio ambient 用 HBONE（mTLS 上的 HTTP/2 CONNECT） | 机制一致；认证是业界多做 | 实验已验证 |
| 4. 保留每台的来源地址 | 网关查一张“真实 IP 对内网 IP”的表做一对一转换，十万条 | Cilium、Calico、OpenShift 的出口网关按标签把一组 Pod 的来源换成指定地址。Istio 没查到对应机制 | 部分一致；一对一和规模是本方案多做 | 实验已验证（十万条映射） |
| 5. 防绕过 | 虚拟机只能到达 Egress；网关入口只对 Egress 开放；Egress 拒绝虚拟机访问网关网段；吊销旧的隧道密钥 | Istio 文档明说自己保证不了出口流量都经过出口网关，要靠防火墙或网络策略。ambient 把代理放到 Pod 外面 | 一致 | 实验已验证；同网段冒用源地址未验证 |
| 6. 令牌被带走后重放 | 服务端按来源地址限定凭证；尽量改用客户端证书 | 绑定发送方的令牌（RFC 8705、RFC 9449）；云上按来源网络写策略条件 | 部分一致 | 实验已验证；真实服务能否限定未验证。已选定再加上短期的身份声明（见第 5 节），未验证 |
| 7. 不走 HTTP 的凭证 | 口令注入不了，列为例外；服务认客户端证书时由 Egress 在四层代为出示 | Teleport、StrongDM 逐个实现数据库协议，代为认证。云数据库用短期令牌代替口令 | 业界多做 | 证书一项实验已验证（最小实现）；口令确认注入不了。已选定交给内网一侧的接入代理（见第 5 节），未验证 |
| 8. 到内网的通路 | 网关上一条站点到站点的 WireGuard 隧道，对端把一整块地址交给网关 | Submariner 在网关节点上建 IPsec 或 WireGuard 隧道。Tailscale 的 Kubernetes operator 用代理 Pod 接入 | 位置一致；整块地址加一对一映射是本方案多做 | 实验已验证；IPsec、SD-WAN、专线未验证 |
| 9. 高可用和扩容 | 地址块是调度单位；Egress 按块分片加热备；网关按单元单活加共享热备，切换时连接断 | Submariner 网关主备。Cilium 开源版可以列多个网关，每个工作负载固定走其中一个；多活和健康检查在企业版 | 部分一致 | 实验已验证；VPN 服务器多台未验证 |
| 10. 互联网出口的管控 | 非 TCP 默认拒绝；按域名放行，并由 Egress 自己解析域名；默认经企业的互联网出口 | Istio 对应用自己发起的 TLS 按 SNI 匹配后透传 | 部分一致 | 设计，未验证 |
| 11. 控制面和逐台阻断 | 整份快照、节点自己拉、原子替换；一个操作在三处阻断一台虚拟机 | 这次没有核对 | — | 映射表原子替换已验证，其余未验证 |

## 3. 逐项说明

### 3.1 加密的位置

问题是同一个：工作负载自己加密之后，代理只能看到密文。

| | 本方案 | Istio | Cilium |
| --- | --- | --- | --- |
| 应用层的 TLS | 虚拟机发明文，Egress 向服务发起 TLS | 应用发明文，边车或出口网关发起 TLS | — |
| 网络层的隧道 | 隧道建在网关上，虚拟机里没有隧道和密钥 | — | 节点上的代理建隧道，每个节点自己生成密钥，Pod 里没有配置 |
| 工作负载自己加密时 | 非指定服务的 TLS 端口原样透传，注入不了凭证 | 按 SNI 匹配后透传，看不到 HTTP 的内容；仍可以按来源的服务账号做策略 | — |

不同的地方：Istio 里应用到边车的明文不出 Pod；本方案里虚拟机到 Egress、Egress 到网关的明文是跨主机的。服务走 TLS 时内容仍是密文，实验里在网关上抓不到凭证；服务是明文 HTTP 加令牌时，令牌在这两段上可见。

### 3.2 凭证注入

| 产品 | 凭证放在哪 | 支持的凭证 | 粒度 |
| --- | --- | --- | --- |
| 本方案的 Egress | Egress 上 | 请求头里的令牌和静态凭证、客户端证书 | 每台虚拟机、每个服务一份 |
| Istio 出口网关 | 网关所在命名空间的 Secret，由目的地规则引用 | 客户端证书 | 每个目的地一份 |
| Istio 边车 | 客户端 Pod 所在命名空间的 Secret，Pod 的服务账号要有读权限 | 客户端证书 | 每个目的地一份 |
| Consul terminating gateway | 网关的配置项里 | 客户端证书（文档只讲了证书） | 每个外部服务一份 |
| Envoy `credential_injector` | Envoy 的密钥发现服务 | 通用请求头、OAuth2 客户端凭证 | 跟着过滤器的配置 |
| Envoy AWS 签名过滤器 | AWS 的凭证链 | SigV4 签名 | 跟着过滤器的配置 |
| Fly.io Tokenizer | 工作负载手里是用代理公钥加密的密文，明文只在代理进程里解出 | 请求头 | 每份密文可以限定目标主机 |

三点值得注意：

- **在边车上做，凭证离工作负载更近。** Istio 的两种做法里，放在出口网关上的那种才和本方案等价。
- **只对指定目的地注入是共识。** Tokenizer 的密文可以限定目标主机，对应本方案“目的地址、端口、Host 都要匹配”。
- **Envoy 的凭证注入过滤器现在还标着 alpha。** 它在 1.30 引入，1.35 起不再标“开发中”，但扩展状态仍是 alpha。[ha-scale-design.md](ha-scale-design.md) 第 10 节计划用外部授权过滤器接本机的凭证代理，是另一条路，两者都没有在实验里试过。

### 3.3 代理之间传递身份

本方案网关的做法和 Envoy 文档里的描述是同一套：下游用 PROXY protocol 带来地址，`original_src` 过滤器以这个地址为源发起上游连接。文档同样指出，回程默认不会回到 Envoy，同机部署时要用标记、连接标记和按标记的策略路由把它收回来。本方案的标记 123 和路由表 100 就是这件事。

和 Istio ambient 的差别在认证：

| | 本方案 | Istio ambient |
| --- | --- | --- |
| 载体 | 明文 TCP 开头的 PROXY 头 | HBONE：mTLS 上的 HTTP/2 CONNECT |
| 下一跳凭什么相信这个声明 | 网络隔离：网关的端口只对 Egress 的地址开放 | 证书：只有持证书的代理能建这条隧道 |
| 已知的后果 | 虚拟机能借 Egress 把伪造的 PROXY 头送到网关，实验证实过，靠 Egress 拒绝访问网关网段来堵 | — |

[ha-scale-design.md](ha-scale-design.md) 第 6 节考虑过把这一段改成 mTLS 上的 CONNECT，没有采用，理由是数据面 B 解决得更彻底。数据面 B 之后已经放弃（见 [transport-options.md](transport-options.md) 第 2 节），这个理由不再成立，值得重新评估。

### 3.4 保留每台的来源地址

| 产品 | 怎么选工作负载 | 换成什么地址 | 粒度 | 经过七层代理后还生效吗 |
| --- | --- | --- | --- | --- |
| 本方案的网关 | 查映射表，键是虚拟机的真实 IP | 这台虚拟机专属的内网 IP，属于经隧道路由过来的地址块 | 每台一个，表里十万条 | 生效，方案就是这样设计的 |
| Cilium Egress Gateway | 策略里按 Pod 的标签选，再加目的网段 | 网关节点网卡上的一个地址 | 一条策略一个地址；把标签收窄到单个 Pod 可以做到每个一个（推断，文档没有这样写） | 1.16 起生效；1.15 及以前不生效 |
| Calico Egress Gateway | 按命名空间或 Pod 的注解 | 出口网关 Pod 的地址 | 命名空间或 Pod。只有企业版和云服务版有 | 没查 |
| OpenShift EgressIP | 命名空间必选，Pod 标签可选 | 配置的出口地址 | 命名空间或其中一组 Pod | 没查 |
| Submariner Globalnet | 集群、命名空间或 Pod | 全局地址池里的地址 | 集群默认 8 个，可以按命名空间或 Pod 另配 | — |
| Istio 出口网关 | — | 文档没有说明外部看到的来源地址 | 没查到让外部看到各工作负载各自地址的机制 | — |

Cilium 那一栏要说明一下。七层策略和出口网关同时选中一个工作负载时流量不走出口网关，这在 1.14、1.15 的文档里列为已知限制，2024 年 6 月修掉，1.16 起文档里不再有这一条。它遇到的正是本方案的问题：流量被重定向到七层代理之后，来源地址的处理被跳过了。

本方案和它们的差别在三处：

- **粒度和规模。** 业界按策略对象配置，一条策略对应一组工作负载；本方案是一张数据表，每台一条记录，新增一台不改配置。
- **地址从哪来。** 业界换成的是网关节点自己的地址；本方案换成的是 VPN 服务器整块交过来的地址，内网按路由把回程送回隧道。
- **业界的主流思路是不靠地址。** 服务网格用证书表示身份，服务端认证书，来源地址是谁就不重要。这要求服务端能改造。本方案的内网服务有令牌和静态凭证两类，只能按来源地址限定，所以地址必须保留。

### 3.5 防绕过

Istio 的出口网关文档有一段专门讲这个：它自己保证不了所有出口流量都经过出口网关，绕过边车就能直连外部，要靠 Istio 之外的手段，例如防火墙、网络策略、不给网关以外的 Pod 分配公网地址。ambient 模式下也一样，把出口登记到 waypoint 并不阻止直连，要另加只放行 waypoint 身份的授权策略。

本方案对应的四条：

| 本方案的要求 | 堵的是哪条路 |
| --- | --- |
| 虚拟机只能到达 Egress | 不经 Egress 直接出去 |
| 网关的入口只对 Egress 开放 | 直接连网关，伪造来源 |
| Egress 拒绝虚拟机访问网关所在的网段 | 借 Egress 的手连网关，伪造来源 |
| 迁移完一台就吊销它的旧隧道密钥 | 自己拨号进内网 |

ambient 把代理从 Pod 里挪到节点上，官方博客给的理由里有安全隔离这一条。本方案的 Egress 和网关一开始就在虚拟机外面，位置上等价于 ambient，而不是边车。

### 3.6 令牌被带走后重放

本方案的结论是：令牌和静态凭证做不到虚拟机拿不到（服务回显就会带回来），只能做到带走了在别处用不了。业界对同一件事有三类手段：

| 手段 | 原理 | 本方案的情况 |
| --- | --- | --- |
| 证书绑定的令牌（RFC 8705） | 令牌绑定到客户端的 TLS 证书，出示令牌的必须是持证书的那一方 | 没有做。证书在 Egress 上，原理上可以结合，要服务端支持 |
| 持有证明（RFC 9449，DPoP） | 令牌绑定到客户端的一把密钥，每个请求带一份签名 | 没有做 |
| 按来源网络限定 | AWS 可以在策略里按来源地址或来源的 VPC 端点写条件 | 已采用：服务端按内网 IP 限定，实验已验证 |

AWS 那一类有两点和本方案不同：它是访问策略上的条件，不是凭证自己的属性；按来源地址的条件只对公网地址有效，请求走 VPC 端点时要改用端点的条件。

2026-11-22 选定的方向和前两类思路相近，但不是照搬这两个标准：Egress 给每个请求带一份自己签名的短期身份声明，服务一侧只在出示了 Egress 证书的连接上才接受它。声明被带回虚拟机也用不了，几分钟后过期。按来源地址限定仍然保留。细节见 [ha-scale-design.md](ha-scale-design.md) 第 10 节，没有验证过。

### 3.7 不走 HTTP 的凭证

| 产品 | 做法 | 工作负载手里有什么 |
| --- | --- | --- |
| 本方案 | 口令：注入不了，留在虚拟机里，列为例外。客户端证书：Egress 在四层代为握手 | 口令，或者什么都没有 |
| Envoy 的 Redis 代理 | 配了上游口令后，Envoy 连上游时自己登录 | 什么都没有 |
| Envoy 的 MySQL、PostgreSQL 过滤器 | 只解析协议、出统计，文档没有提到代为登录；都标着实验性 | 口令 |
| Teleport | 解析各种数据库的协议；自建的库用双向 TLS，云上的库用云平台的身份认证 | 短期的客户端证书 |
| StrongDM | 协议代理在到数据库的最后一跳注入凭证 | 什么都没有 |
| HashiCorp Boundary | 注入只支持 SSH 和 RDP；数据库只能用“代为申请凭证再交给用户”的方式 | 数据库的凭证 |
| AWS RDS 的 IAM 认证 | 用有效期 15 分钟的令牌代替口令 | 能生成令牌的云平台身份 |
| Cloud SQL Auth Proxy | 代理负责授权和 TLS；默认仍要数据库账号和口令，开了 IAM 认证才由短期令牌充当口令 | 默认是口令 |

本方案用 Envoy 的 Redis 代理试过，失败的原因不在 Redis 代理本身，而在它使用自己的上游连接，带不上虚拟机的身份（见 [design.md](design.md) 的“凭证不落到虚拟机”）。专门的协议代理产品面对的是“人或应用连数据库”，不需要把来源地址带到数据库那一侧，所以没有这个障碍。

2026-11-22 选定的方向是把这类代理放到内网一侧、数据库的前面：连接到它那里时来源已经是虚拟机的内网 IP，它按来源认出虚拟机，替它登录，口令放在它上面。PostgreSQL 可以用 PgBouncer，MySQL 还没有确定可用的现成做法。细节见 [ha-scale-design.md](ha-scale-design.md) 第 10 节，没有验证过。

### 3.8 到内网的通路

| 产品 | 隧道建在哪 | 协议 | 对端看到的来源 |
| --- | --- | --- | --- |
| 本方案 | VPN 网关 | WireGuard；计划加 IPsec | 每台虚拟机专属的内网 IP |
| Submariner | 带网关标签的节点 | IPsec（默认）、WireGuard、VXLAN（不加密） | 不开 Globalnet 时尽量保留 Pod 的地址；开了是全局地址 |
| Tailscale 的 Kubernetes operator | 代理 Pod，每个服务一个或共用一组 | WireGuard | 文档没有直接说明；代理本身是网络里的一台设备（推断是代理的） |
| Cilium 透明加密 | 每个节点 | WireGuard 或 IPsec | 集群内部的 Pod 地址 |

共同点是隧道不进工作负载。Submariner 不开 Globalnet 的做法最接近“保留各自的地址”，前提是两边的地址不冲突、可以直接路由；本方案的虚拟机真实地址和内网地址是两套，所以多了一层映射。

### 3.9 高可用和扩容

| | 本方案 | 业界 |
| --- | --- | --- |
| 做地址转换的网关 | 按单元单活，N+1 共享热备。断电后新连接 3.8 到 4.7 秒恢复，已有连接全断 | Submariner 网关是主备。Cilium 开源版可以列多个网关，每个工作负载固定走其中一个，文档里没有健康检查和故障切换。Cilium 企业版据厂商博客是一组网关多活、带健康检查，正式文档要登录，没读到 |
| 七层代理 | Egress 按地址块分片，互为热备。断电后约 4 秒恢复，已有连接全断 | Istio 网关的文档只给了通用建议（自动伸缩、中断预算、优雅退出），没查到副本故障时已有连接怎么样 |
| 扩容的单位 | 地址块 | 副本数；出口网关是策略加网关节点 |

本方案把“网关有状态，切换必断连接”写成了已知限制。这次没有查到哪个产品说明了做地址转换的网关故障时已有连接能保住。

### 3.10 互联网出口的管控

Istio 对应用自己发起的 TLS，按握手里的服务器名称匹配后透传。[ha-scale-design.md](ha-scale-design.md) 第 8 节比这多一步：不采用虚拟机给的目的地址，由 Egress 自己解析域名再连，防止虚拟机在名称里写一个允许的域名、实际连到别处。这一步没有在实验里验证过；Istio 怎么处理这种情况，这次没有核对。

“默认经企业的互联网出口”“非 TCP 默认拒绝”这两项，这次没有找业界的对应做法。

### 3.11 控制面和逐台阻断

这一方面这次没有核对。服务网格的控制面是向代理推送配置，这是它的基本工作方式；本方案计划的“整份快照、节点自己拉、原子替换”和“一个操作在三处阻断一台虚拟机”有没有现成的对应做法，没有查。

## 4. 本方案多做的

| 多做的 | 为什么业界通常不做 | 本方案为什么要做 |
| --- | --- | --- |
| 来源地址每台一个，一对一映射，几万台 | 身份用证书表示，或者出口地址按命名空间分 | 内网服务按地址做访问控制和凭证的来源限定，每台的内网 IP 不能变 |
| 凭证按虚拟机区分 | 出口网关用自己的身份访问外部服务，一个目的地一份凭证 | 服务要认出是哪台虚拟机；泄露后能只作废一台 |
| 转换后的地址是经隧道路由来的一整块 | 出口网关的地址就在网关节点的网卡上 | 内网地址由 VPN 服务器分配，回程要从隧道回来 |
| 新旧两种接入方式并存、逐台迁移和回退 | — | 存量虚拟机各自有隧道，不能一次切换 |

第二项带来一个业界没有的难题：Envoy 向上游发起 TLS 时用哪张客户端证书是跟着上游集群配置的，不能按请求选。按虚拟机出示证书在规模上去之后怎么做，[ha-scale-design.md](ha-scale-design.md) 第 10 节原来列了三个候选。2026-11-22 选定的是向业界靠拢的那一个：Egress 只用自己的一张证书，是哪台虚拟机由每个请求里的身份声明说明。没有验证过。

## 5. 业界有、本方案没做的

都没有验证过。最后一列是 2026-11-22 的决定。

| 业界的做法 | 对本方案的意义 | 代价 | 决定 |
| --- | --- | --- | --- |
| 出口网关用自己的身份，令牌绑定发送方，短期令牌 | 每台一张证书扩不到几万台；令牌被服务回显带回虚拟机后还能用；共用账号没法只作废一台 | 内网服务要改造，或者前面放校验代理 | 采用。合成一项：Egress 用一张证书，每个请求带短期的身份声明。写进了 [ha-scale-design.md](ha-scale-design.md) 第 10 节 |
| 非 HTTP 协议的凭证代理 | 口令留在虚拟机里是本方案最大的例外 | 内网一侧多一个存口令的组件；数据库看到的来源变成它的地址 | 采用。放在内网一侧、数据库前面。写进了同一节 |
| 代理之间的身份声明带认证（HBONE 的做法） | Egress 到网关这一段现在只靠网络隔离。加上 mTLS 之后，伪造 PROXY 头要先拿到 Egress 的证书 | 多一层握手；证书的签发和轮换 | 暂不评估 |
| 虚拟机携带加密后的凭证，代理解密后注入（Tokenizer 的做法） | Egress 上不用存每台虚拟机的凭证表 | 应用要自己带请求头；虚拟机里多了一份密文 | 不做 |
| 网关多活加健康检查 | 现在是单活加热备，容量不能叠加 | 做地址转换的节点有状态；数据面 B 试过这条路，已放弃 | 不做 |

## 6. 依据和没查到的

查阅方式：2026-11-22 读各产品官方文档的当前版本；Cilium 那一处修复另外直接读了官方仓库里的合并请求。没有运行任何产品。

**没查到直接依据，或者只是推断的：**

- Istio：流量经过出口网关之后外部看到的来源地址；出口网关副本故障时已有连接怎么样。
- Istio：“应用自己发起 TLS 时看不到七层”“ambient 的安全隔离”这两条的明文在官方博客里，现行文档没有同样的话。ztunnel 保留来源地址的行为只在仓库的设计文档里。
- Cilium：把策略收窄到单个 Pod、每个 Pod 一个出口地址，文档没有这样写，是按字段推出来的。企业版高可用的正式文档没读到。多个网关时网关变更对已有连接的影响，没有找到可靠的出处。
- Tailscale：对端看到的是谁的身份和地址，文档没有直接写。
- Teleport：“用户拿不到数据库口令”没有逐字的出处，是从它的认证方式推出来的。
- Envoy：MySQL、PostgreSQL 过滤器“不做凭证注入”是文档没有提到，不是文档明说不支持。
- OpenShift：官方站点读不到，依据的是同源的 OKD 文档。

**这次没有核对的方面：** 控制面的下发方式、逐台阻断、互联网流量经企业出口、非 TCP 流量的处理、迁移。

**主要出处：**

- Istio：[出口网关](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/)、[出口网关发起 TLS](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/)、[边车发起 TLS](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/)、[ambient 概览](https://istio.io/latest/docs/ambient/overview/)、[HBONE](https://istio.io/latest/docs/ambient/architecture/hbone/)、[ambient 的出口网关](https://istio.io/latest/docs/ambient/usage/egress-gateway/)、[ztunnel 设计文档](https://github.com/istio/istio/blob/master/architecture/ambient/ztunnel.md)
- Envoy：[IP Transparency](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/other_features/ip_transparency)、[original_src 过滤器](https://www.envoyproxy.io/docs/envoy/latest/configuration/listeners/listener_filters/original_src_filter)、[凭证注入过滤器](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/credential_injector_filter)、[AWS 签名过滤器](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/aws_request_signing_filter)、[Redis 代理](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/other_protocols/redis)
- Consul：[terminating gateway](https://developer.hashicorp.com/consul/docs/north-south/terminating-gateway)
- Cilium：[Egress Gateway](https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/)、[1.15 的限制说明](https://docs.cilium.io/en/v1.15/network/egress-gateway/)、[修复七层策略不兼容的合并请求](https://github.com/cilium/cilium/pull/32828)、[WireGuard 加密](https://docs.cilium.io/en/stable/security/network/encryption-wireguard/)
- 其他出口网关：[Calico](https://docs.tigera.io/use-cases/egress-gateways)、[OKD EgressIP](https://docs.okd.io/latest/networking/ovn_kubernetes_network_provider/configuring-egress-ips-ovn.html)
- 隧道：[Submariner 网关](https://submariner.io/getting-started/architecture/gateway-engine/)、[Submariner Globalnet](https://submariner.io/getting-started/architecture/globalnet/)、[Tailscale 集群出口](https://tailscale.com/kb/1438/kubernetes-operator-cluster-egress)
- 凭证代理：[Teleport](https://goteleport.com/docs/reference/architecture/agents/)、[Boundary 的凭证管理](https://developer.hashicorp.com/boundary/docs/concepts/credential-management)、[StrongDM](https://docs.strongdm.com/concepts/security/credentials-and-secrets-management)、[RDS 的 IAM 认证](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.html)、[Cloud SQL 的 IAM 认证](https://docs.cloud.google.com/sql/docs/mysql/iam-authentication)、[Tokenizer](https://github.com/superfly/tokenizer)
- 令牌：[RFC 8705](https://www.rfc-editor.org/rfc/rfc8705.html)、[RFC 9449](https://www.rfc-editor.org/rfc/rfc9449.html)、[AWS 的全局条件键](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html)
