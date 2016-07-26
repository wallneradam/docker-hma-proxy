#!/bin/bash

# Add new route with better metrics
route add -net 0.0.0.0 netmask 128.0.0.0 gw ${route_vpn_gateway} dev ${dev} metric 1
route add -net 128.0.0.0 netmask 128.0.0.0 gw ${route_vpn_gateway} dev ${dev} metric 1

# Kill old OpenVPN process(es)
processes=`ps -o etime,pid,comm | grep openvpn | grep -v grep | grep -v watch | sort`
lc=`echo "$processes" | wc -l`
OIFS=$IFS; IFS=$'\n'; processes=(${processes}); IFS=$OIFS
for ((i=1;i<$lc;i++)); do
    process=${processes[$i]}
    pid=`echo "$process" | awk '{print $2}'`
    /opt/ip-changer.sh "kill" "$pid" &>/dev/null

    # Remove old gateway host
    r=`route -n | grep 'UGH' | grep -v ${untrusted_ip} | tail -1`
    oldUIP=`echo "$r" | awk '{print $1}'`
    if [ "$oldUIP" != "" ]; then route del -host ${oldUIP} &>/dev/null; fi
done

# Change metrics
route add -net 0.0.0.0 netmask 128.0.0.0 gw ${route_vpn_gateway} dev ${dev} metric 10 &>/dev/null
route add -net 128.0.0.0 netmask 128.0.0.0 gw ${route_vpn_gateway} dev ${dev} metric 10 &>/dev/null
route del -net 0.0.0.0 netmask 128.0.0.0 gw ${route_vpn_gateway} dev ${dev} metric 1 &>/dev/null
route del -net 128.0.0.0 netmask 128.0.0.0 gw ${route_vpn_gateway} dev ${dev} metric 1 &>/dev/null

# For debug
# env >/tmp/env.txt
