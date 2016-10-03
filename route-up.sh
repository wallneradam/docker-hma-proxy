#!/bin/bash

num=`echo "${dev}" | sed 's|tun||'`

sysctl -w net.ipv4.conf.${dev}.rp_filter=2

iptables -t nat -A POSTROUTING -o ${dev} -m mark --mark ${num} -j SNAT --to-source ${ifconfig_local}
ip route add default via ${route_vpn_gateway} dev ${dev} table proxy${num}
ip route flush cache

tinyproxy -c /etc/tinyproxy/tinyproxy${num}.conf


## For debug
#env >/tmp/up_env.txt
