#!/bin/bash

# Start self in background, so we can wait a little before we turn off old VPN
if [ "$1" != "bg" ]; then
    nohup $0 bg &
    exit
fi

# Add new route with better metrics, but old connections still alive
route add -net 0.0.0.0 netmask 128.0.0.0 gw ${route_vpn_gateway} dev ${dev} metric 1
route add -net 128.0.0.0 netmask 128.0.0.0 gw ${route_vpn_gateway} dev ${dev} metric 1

# Wait 10 seconds for new vpn being established and old connections being done
sleep 10

# Kill old OpenVPN process(es)
processes=`ps -o etime,pid,comm | grep openvpn | grep -v grep | grep -v watch | sort`
lc=`echo "$processes" | wc -l`
OIFS=$IFS; IFS=$'\n'; processes=(${processes}); IFS=$OIFS
for ((i=1;i<$lc;i++)); do
    # Kill old VPN
    process=${processes[$i]}
    pid=`echo "$process" | awk '{print $2}'`
    /opt/ip-changer.sh "kill" "$pid" &>/dev/null

    # Remove old gateway host
    r=`route -n | grep 'UGH' | grep -v ${untrusted_ip} | tail -1`
    oldUIP=`echo "$r" | awk '{print $1}'`
    if [ "$oldUIP" != "" ]; then route del -host ${oldUIP} &>/dev/null; fi
done

# Change metrics to 10, so the future VPN can have priority again
route add -net 0.0.0.0 netmask 128.0.0.0 gw ${route_vpn_gateway} dev ${dev} metric 10 &>/dev/null
route add -net 128.0.0.0 netmask 128.0.0.0 gw ${route_vpn_gateway} dev ${dev} metric 10 &>/dev/null
route del -net 0.0.0.0 netmask 128.0.0.0 gw ${route_vpn_gateway} dev ${dev} metric 1 &>/dev/null
route del -net 128.0.0.0 netmask 128.0.0.0 gw ${route_vpn_gateway} dev ${dev} metric 1 &>/dev/null

# For debug
# env >/tmp/env.txt
