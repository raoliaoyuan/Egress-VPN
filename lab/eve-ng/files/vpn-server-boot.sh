#!/bin/bash
# VPN 服务器每次开机执行：内核参数，以及去内网服务网段的路由。
# VPN 服务器和内网服务之间隔着内网核心路由器（rtr-core）：服务器在 CORE-NET 上，内网服务在 rtr-core 后面。
# 只有一台服务器时这条路由是静态的；多台服务器的形态下内网网段从 BGP 学来（这里不加，免得盖住）。
. /etc/lab/ifaces.env
/etc/lab/tune.sh
[ -e /etc/lab/ms-on ] || ip route replace 10.200.5.0/24 via 10.200.0.1 dev "$IF_CORE_NET"
exit 0
