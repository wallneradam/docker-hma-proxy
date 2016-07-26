#!/bin/bash
ip=""
attempt=0
while [ "$attempt" -lt "3" ]; do
	attempt=$(($attempt+1))
	sleep 1
	if [[ "$ip" == "" ]] ; then
	ip=$(/usr/bin/curl -k --connect-timeout 5 -s --connect-timeout 10 --max-time 10 geoip.hmageo.com/ip/ 2>/dev/null)
	fi
	if [[ "$ip" == "" ]] ; then
	sleep 1
	ip=$(/usr/bin/curl -k --connect-timeout 5 -s --connect-timeout 10 --max-time 10 icanhazip.com 2>/dev/null)
	fi
	if [[ "$ip" == "" ]] ; then
	sleep 1
	ip=$(/usr/bin/curl -k --connect-timeout 5 -s --connect-timeout 10 --max-time 10 ipecho.net/plain 2>/dev/null)
	else
	attempt=3
	fi
done

if [[ "$ip" == "" ]] ; then
	echo "Failed to check IP address."
else
	echo "Your IP is $ip"
fi
