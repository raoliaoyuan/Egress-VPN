#!/usr/bin/env python3
"""生成实验里 Egress 的 Envoy 配置，输出到标准输出。
用法：gen-egress-envoy.py baseline|solution --state <state 目录> --vm 名字=地址 [--vm …] [--unscoped] [--redis-inject]

Egress 透明劫持虚拟机发来的全部 TCP。80、8081、8443、9443 端口进七层监听器，其余端口按四层转发。
- baseline：现状。Egress 看到的流量都直接发往原目的地。
- solution：新方案。目的地址属于内网的流量改为交给 VPN 网关，上游取自仓库里的
  config/egress/vpn-gateway-cluster.yaml（只把网关域名换成实验里的服务地址）。

凭证的处理（目标是虚拟机拿不到凭证）：
- 只对 SERVICES 里列出的服务注入，按“目的地址 + 端口 + Host”匹配；发往别处的请求不带凭证。
- 凭证按虚拟机区分，用来源地址选择。--vm 没有列出的虚拟机，请求照常转发但不带凭证。
- HTTP 服务的四种形式：token 是明文 HTTP 加令牌请求头；token-tls 是 Egress 向服务发起 TLS 后加令牌请求头；
  basic 是加 Authorization: Basic，里面是所有虚拟机共用的一个账号和口令（静态凭证）；
  mtls 是 Egress 用这台虚拟机的客户端证书向服务发起 TLS，不加请求头，私钥不在线路上传输。
- 非 HTTP 的服务（SERVICES 里的 tcp）：Egress 不解析内容，只能在四层用这台虚拟机的客户端证书发起 TLS。
  靠口令登录的非 HTTP 服务，这里不注入，流量按四层原样转发，口令只能由虚拟机自己带。
- 虚拟机自带的同名请求头会被覆盖或删除；TRACE 方法（会回显整个请求）在 Egress 上拒绝。
- 不开 Envoy 的管理接口，它能导出含凭证的完整配置。

--unscoped 只用于对照实验：另外对每台虚拟机发往任意目的地 80 端口的请求也注入，重现“不按目的地限定”的后果。
--redis-inject 只用于试验：内网服务的 6379 端口改用 Envoy 的 Redis 代理，由它替虚拟机登录。
用来看这种做法在本方案里行不行得通（它的上游连接不与某一条下游连接对应，带不了虚拟机的身份）。

这里的监听器是按“透明劫持”假设写的参考实现，不是真实的 Egress。
"""
import argparse
import base64
import copy
import os
import sys

import yaml

ap = argparse.ArgumentParser()
ap.add_argument("stage", choices=["baseline", "solution"])
ap.add_argument("--state", required=True)
ap.add_argument("--vm", action="append", default=[], metavar="名字=地址")
ap.add_argument("--unscoped", action="store_true")
ap.add_argument("--redis-inject", action="store_true")
ARGS = ap.parse_args()

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
INTRANET = {"address_prefix": "10.200.0.0", "prefix_len": 16}
GATEWAY = "10.1.255.10"
HEADER = "x-egress-credential"
HTTP_PORTS = [80, 8081, 8443, 9443]   # 要与 egress.nft 里重定向到七层监听器的端口一致
PLAIN_HTTP = (80, 8081)               # 其中虚拟机和服务之间本来就是明文 HTTP 的端口
REDIS_PORT = 6379
CLIENT_DIR = "/etc/lab/client"  # Egress 上存放各虚拟机客户端证书的目录
SERVICES = [
    {"name": "intranet-svc", "ip": "10.200.5.6", "via_gateway": True,
     "ports": {80: "token", 8081: "basic", 8443: "token-tls", 9443: "mtls"}, "tcp": {6380: "mtls"}},
    {"name": "public-web", "ip": "203.0.113.80", "via_gateway": False, "ports": {80: "token"}},
]
VMS = dict(v.split("=", 1) for v in ARGS.vm)
SOLUTION = ARGS.stage == "solution"


def token(vm, service):
    return open(os.path.join(ARGS.state, "creds", f"{vm}.{service}.token")).read().strip()


def shared(service):
    """这个服务上所有虚拟机共用的静态凭证，“账号:口令”。"""
    return open(os.path.join(ARGS.state, "creds", f"{service}.shared")).read().strip()


def host(ip):
    return {"address_prefix": ip, "prefix_len": 32}


def tcp_filter(cluster):
    return {
        "name": "envoy.filters.network.tcp_proxy",
        "typed_config": {
            "@type": "type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy",
            "stat_prefix": "tcp_" + cluster, "cluster": cluster,
        },
    }


def http_filter(vhost):
    return {
        "name": "envoy.filters.network.http_connection_manager",
        "typed_config": {
            "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
            "stat_prefix": "http_" + vhost["name"],
            "route_config": {"virtual_hosts": [vhost]},
            "http_filters": [{
                "name": "envoy.filters.http.router",
                "typed_config": {"@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"},
            }],
        },
    }


def chain(match, filt):
    return {"filter_chain_match": match, "filters": [filt]}


def inject(header, value):
    return [{"header": {"key": header, "value": value}, "append_action": "OVERWRITE_IF_EXISTS_OR_ADD"}]


def plain_vhost(cluster):
    """不属于任何指定服务的请求：原样转发，不注入。"""
    return {"name": "other_" + cluster, "domains": ["*"],
            "routes": [{"match": {"prefix": "/"}, "route": {"cluster": cluster}}]}


def service_vhost(svc, port, vm):
    """指定服务的请求。vm 为 None 表示来源不是已知的虚拟机，不给凭证。"""
    mode = svc["ports"][port]
    if not svc["via_gateway"]:
        cluster = "direct"
    elif mode in ("token", "basic"):
        cluster = "vpn_gateway_1"
    elif mode == "mtls" and vm:
        cluster = "vpn_gateway_1_mtls_" + vm
    else:
        cluster = "vpn_gateway_1_tls"
    vhost = {
        "name": f"{svc['name']}_{port}_{vm or 'nocred'}",
        # Host 也要对得上：目的地址是这个服务、Host 却指向别处的请求不转发（Envoy 返回 404）。
        "domains": [svc["ip"], f"{svc['ip']}:{port}", svc["name"], f"{svc['name']}:{port}"],
        "routes": [
            {"match": {"prefix": "/", "headers": [{"name": ":method", "string_match": {"exact": "TRACE"}}]},
             "direct_response": {"status": 405}},
            {"match": {"prefix": "/"}, "route": {"cluster": cluster}},
        ],
    }
    if vm and mode in ("token", "token-tls"):
        vhost["request_headers_to_add"] = inject(HEADER, token(vm, svc["name"]))
    elif vm and mode == "basic":
        vhost["request_headers_to_add"] = inject(
            "authorization", "Basic " + base64.b64encode(shared(svc["name"]).encode()).decode())
    else:
        vhost["request_headers_to_remove"] = ["authorization" if mode == "basic" else HEADER]
    return vhost


clusters = [{"name": "direct", "type": "ORIGINAL_DST", "lb_policy": "CLUSTER_PROVIDED", "connect_timeout": "5s"}]

if SOLUTION:
    frag = yaml.safe_load(open(os.path.join(REPO, "config", "egress", "vpn-gateway-cluster.yaml")))["clusters"][0]
    ep = frag["load_assignment"]["endpoints"][0]["lb_endpoints"][0]["endpoint"]
    ep["address"]["socket_address"]["address"] = GATEWAY
    clusters.append(frag)

    def tls_cluster(name, client_cert=None):
        """同一个上游，最里层换成 TLS：握手在 Egress 与内网服务之间完成，网关只看到密文。"""
        c = copy.deepcopy(frag)
        c["name"] = c["load_assignment"]["cluster_name"] = name
        common = {"validation_context": {
            "trusted_ca": {"filename": "/etc/lab/intranet-ca.pem"},
            "match_typed_subject_alt_names": [{"san_type": "DNS", "matcher": {"exact": "intranet-svc"}}],
        }}
        if client_cert:
            common["tls_certificates"] = [{
                "certificate_chain": {"filename": f"{CLIENT_DIR}/{client_cert}.pem"},
                "private_key": {"filename": f"{CLIENT_DIR}/{client_cert}.key"},
            }]
        c["transport_socket"]["typed_config"]["transport_socket"] = {
            "name": "envoy.transport_sockets.tls",
            "typed_config": {
                "@type": "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext",
                "sni": "intranet-svc", "common_tls_context": common,
            },
        }
        return c

    clusters.append(tls_cluster("vpn_gateway_1_tls"))
    for vm in VMS:
        clusters.append(tls_cluster("vpn_gateway_1_mtls_" + vm, client_cert=vm))

# 七层监听器的过滤链。Envoy 先按目的端口、再按目的地址、最后按来源地址逐级收窄，收窄后不会回头，
# 所以每个端口下都要有完整的兜底：指定服务（带凭证、不带凭证）、内网其余地址、其余所有地址。
http_chains = []
for port in HTTP_PORTS:
    for svc in SERVICES:
        if port not in svc["ports"] or (svc["via_gateway"] and not SOLUTION):
            continue
        dst = {"destination_port": port, "prefix_ranges": [host(svc["ip"])]}
        for vm, ip in VMS.items():
            http_chains.append(chain({**dst, "source_prefix_ranges": [host(ip)]}, http_filter(service_vhost(svc, port, vm))))
        http_chains.append(chain(dst, http_filter(service_vhost(svc, port, None))))
    if ARGS.unscoped and port == 80:
        for vm, ip in VMS.items():
            vhost = plain_vhost("direct")
            vhost["name"] = "unscoped_" + vm
            vhost["request_headers_to_add"] = inject(HEADER, token(vm, "intranet-svc"))
            http_chains.append(chain({"destination_port": port, "source_prefix_ranges": [host(ip)]}, http_filter(vhost)))
    # 不是指定服务的：80、8081 端口仍按 HTTP 转发，8443、9443 原样透传（虚拟机自己做 TLS）。
    for match, cluster in ([({"destination_port": port, "prefix_ranges": [INTRANET]}, "vpn_gateway_1")] if SOLUTION else []) \
            + [({"destination_port": port}, "direct")]:
        http_chains.append(chain(match, http_filter(plain_vhost(cluster)) if port in PLAIN_HTTP else tcp_filter(cluster)))

# 四层监听器的过滤链。一个端口一旦有了专门的过滤链，这个端口上的连接就只在这些链里匹配，
# 所以专门处理的端口同样要带齐兜底：指定服务不带凭证的、内网其余地址、其余所有地址。
tcp_chains = []
if SOLUTION:
    for svc in SERVICES:
        for port in svc.get("tcp", {}):
            dst = {"destination_port": port, "prefix_ranges": [host(svc["ip"])]}
            # 用这台虚拟机的客户端证书在四层发起 TLS：虚拟机发明文，Egress 不看内容，只负责握手。
            for vm, ip in VMS.items():
                tcp_chains.append(chain({**dst, "source_prefix_ranges": [host(ip)]}, tcp_filter("vpn_gateway_1_mtls_" + vm)))
            tcp_chains.append(chain(dst, tcp_filter("vpn_gateway_1")))
            tcp_chains.append(chain({"destination_port": port, "prefix_ranges": [INTRANET]}, tcp_filter("vpn_gateway_1")))
            tcp_chains.append(chain({"destination_port": port}, tcp_filter("direct")))
    if ARGS.redis_inject:
        user, password = shared("intranet-svc").split(":", 1)
        c = copy.deepcopy(frag)
        c["name"] = c["load_assignment"]["cluster_name"] = "vpn_gateway_1_redis"
        c["typed_extension_protocol_options"] = {"envoy.filters.network.redis_proxy": {
            "@type": "type.googleapis.com/envoy.extensions.filters.network.redis_proxy.v3.RedisProtocolOptions",
            "auth_username": {"inline_string": user}, "auth_password": {"inline_string": password},
        }}
        clusters.append(c)
        redis = {
            "name": "envoy.filters.network.redis_proxy",
            "typed_config": {
                "@type": "type.googleapis.com/envoy.extensions.filters.network.redis_proxy.v3.RedisProxy",
                "stat_prefix": "redis", "settings": {"op_timeout": "5s"},
                "prefix_routes": {"catch_all_route": {"cluster": "vpn_gateway_1_redis"}},
            },
        }
        tcp_chains.append(chain({"destination_port": REDIS_PORT, "prefix_ranges": [host(SERVICES[0]["ip"])]}, redis))
        tcp_chains.append(chain({"destination_port": REDIS_PORT, "prefix_ranges": [INTRANET]}, tcp_filter("vpn_gateway_1")))
        tcp_chains.append(chain({"destination_port": REDIS_PORT}, tcp_filter("direct")))
    tcp_chains.append(chain({"prefix_ranges": [INTRANET]}, tcp_filter("vpn_gateway_1")))
tcp_chains.append({"filters": [tcp_filter("direct")]})

ORIGINAL_DST = {
    "name": "envoy.filters.listener.original_dst",
    "typed_config": {"@type": "type.googleapis.com/envoy.extensions.filters.listener.original_dst.v3.OriginalDst"},
}
listeners = [
    {"name": "intercept_tcp", "address": {"socket_address": {"address": "0.0.0.0", "port_value": 15006}},
     "listener_filters": [ORIGINAL_DST], "filter_chains": tcp_chains},
    {"name": "intercept_http", "address": {"socket_address": {"address": "0.0.0.0", "port_value": 15007}},
     "listener_filters": [ORIGINAL_DST], "filter_chains": http_chains,
     "default_filter_chain": {"filters": [tcp_filter("direct")]}},
]
yaml.safe_dump({"static_resources": {"listeners": listeners, "clusters": clusters}}, sys.stdout, sort_keys=False)
