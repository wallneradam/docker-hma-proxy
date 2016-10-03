#!/bin/sh

num=`echo "${dev}" | sed 's|tun||'`

kill $(cat /var/run/tinyproxy/tinyproxy${num}.pid) &>/dev/null
truncate -s /var/log/tinyproxy/tinyproxy${num}.log &>/dev/null

ip route del default via ${route_vpn_gateway} dev ${dev} table proxy${num} &>/dev/null
iptables -t nat -D POSTROUTING -o ${dev} -m mark --mark ${num} -j SNAT --to-source ${ifconfig_local} &>/dev/null

# For debug
#env >/tmp/down_env.txt
