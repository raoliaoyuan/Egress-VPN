#!/bin/bash
# vm-farm 每次开机执行：把块 2、块 3 的虚拟机网段整段设成本机地址，
# 这样压测工具可以给每条连接绑定不同的源地址，一个节点就能模拟大量虚拟机。
/etc/lab/tune.sh
ip route replace local 10.2.0.0/16 dev lo
ip route replace local 10.3.0.0/16 dev lo
exit 0
