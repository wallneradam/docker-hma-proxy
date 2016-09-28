#!/bin/bash

# Kill old OpenVPN processes if there are 3 (fallback)
# Normally it should be impossible, but somehow, it can be occured
processes=`ps -o etime,pid,comm | grep openvpn | grep -v grep | grep -v watch | sort`
lc=`echo "$processes" | wc -l`
OIFS=$IFS; IFS=$'\n'; processes=(${processes}); IFS=$OIFS
for ((i=2;i<$lc;i++)); do
    process=${processes[$i]}
    pid=`echo "$process" | awk '{print $2}'`
    kill -9 "$pid" &>/dev/null
    upshs=`pidof up.sh`
    for upid in $upshs; do
        if [ $upid -ne $$ ]; then
            kill -9 "$pid"
        fi
    done
done
