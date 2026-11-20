#!/usr/bin/env python3
"""生成实验里 Egress 的 Envoy 配置，输出到标准输出。
用法：gen-egress-envoy.py baseline|solution <凭证>

Egress 透明劫持虚拟机发来的全部 TCP：80 和 8443 端口按 HTTP 处理并注入凭证头，其余端口按四层转发。
- baseline：现状。Egress 看到的流量都直接发往原目的地。
- solution：新方案。目的地址属于内网的流量改为交给 VPN 网关，上游取自仓库里的
  config/egress/vpn-gateway-cluster.yaml（只把网关域名换成实验里的服务地址）；
  去往内网 8443 端口的请求由 Egress 向内网服务发起 TLS。
这里的监听器是按“透明劫持”假设写的参考实现，不是真实的 Egress。
"""
import copy
import os
import sys

import yaml

STAGE, CREDENTIAL = sys.argv[1], sys.argv[2]
REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
INTRANET = {"address_prefix": "10.200.0.0", "prefix_len": 16}
GATEWAY = "10.1.255.10"

ORIGINAL_DST = {
    "name": "envoy.filters.listener.original_dst",
    "typed_config": {"@type": "type.googleapis.com/envoy.extensions.filters.listener.original_dst.v3.OriginalDst"},
}


def tcp_chain(cluster, match=None):
    chain = {"filters": [{
        "name": "envoy.filters.network.tcp_proxy",
        "typed_config": {
            "@type": "type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy",
            "stat_prefix": "tcp_" + cluster, "cluster": cluster,
        },
    }]}
    if match:
        chain["filter_chain_match"] = match
    return chain


def http_chain(cluster, match=None):
    chain = {"filters": [{
        "name": "envoy.filters.network.http_connection_manager",
        "typed_config": {
            "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
            "stat_prefix": "http_" + cluster,
            "route_config": {"virtual_hosts": [{
                "name": "all", "domains": ["*"],
                # 凭证只存在于 Egress：在这里加到请求上，虚拟机拿不到。
                "request_headers_to_add": [{
                    "header": {"key": "x-egress-credential", "value": CREDENTIAL},
                    "append_action": "OVERWRITE_IF_EXISTS_OR_ADD",
                }],
                "routes": [{"match": {"prefix": "/"}, "route": {"cluster": cluster}}],
            }]},
            "http_filters": [{
                "name": "envoy.filters.http.router",
                "typed_config": {"@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"},
            }],
        },
    }]}
    if match:
        chain["filter_chain_match"] = match
    return chain


clusters = [{"name": "direct", "type": "ORIGINAL_DST", "lb_policy": "CLUSTER_PROVIDED", "connect_timeout": "5s"}]
tcp_chains, http_chains = [], []

if STAGE == "solution":
    frag = yaml.safe_load(open(os.path.join(REPO, "config", "egress", "vpn-gateway-cluster.yaml")))["clusters"][0]
    ep = frag["load_assignment"]["endpoints"][0]["lb_endpoints"][0]["endpoint"]
    ep["address"]["socket_address"]["address"] = GATEWAY
    clusters.append(frag)

    # 同一个上游，最里层换成 TLS：握手在 Egress 与内网服务之间完成，网关只看到密文。
    tls = copy.deepcopy(frag)
    tls["name"] = tls["load_assignment"]["cluster_name"] = "vpn_gateway_1_tls"
    tls["transport_socket"]["typed_config"]["transport_socket"] = {
        "name": "envoy.transport_sockets.tls",
        "typed_config": {
            "@type": "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext",
            "sni": "intranet-svc",
            "common_tls_context": {"validation_context": {
                "trusted_ca": {"filename": "/etc/lab/intranet-ca.pem"},
                "match_typed_subject_alt_names": [{
                    "san_type": "DNS", "matcher": {"exact": "intranet-svc"},
                }],
            }},
        },
    }
    clusters.append(tls)

    tcp_chains.append(tcp_chain("vpn_gateway_1", {"prefix_ranges": [INTRANET]}))
    http_chains.append(http_chain("vpn_gateway_1_tls", {"prefix_ranges": [INTRANET], "destination_port": 8443}))
    http_chains.append(http_chain("vpn_gateway_1", {"prefix_ranges": [INTRANET]}))

tcp_chains.append(tcp_chain("direct"))
http_chains.append(http_chain("direct"))

listeners = [
    {"name": "intercept_tcp", "address": {"socket_address": {"address": "0.0.0.0", "port_value": 15006}},
     "listener_filters": [ORIGINAL_DST], "filter_chains": tcp_chains},
    {"name": "intercept_http", "address": {"socket_address": {"address": "0.0.0.0", "port_value": 15007}},
     "listener_filters": [ORIGINAL_DST], "filter_chains": http_chains},
]
yaml.safe_dump({"static_resources": {"listeners": listeners, "clusters": clusters}}, sys.stdout, sort_keys=False)
