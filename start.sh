#!/bin/bash

# Handle signals
function _trap() {
    if [ ${ip_changer_pid} -ne 0 ]; then kill -SIGTERM ${ip_changer_pid} &>/dev/null; wait ${ip_changer_pid}; fi

    if [ ${proxy_pid} -ne 0 ]; then kill ${proxy_pid} &>/dev/null; wait ${proxy_pid}; fi

    [ -f /var/run/tinyproxy/tinyproxy1.pid ] && kill $(cat /var/run/tinyproxy/tinyproxy1.pid)
    [ -f /var/run/tinyproxy/tinyproxy2.pid ] && kill $(cat /var/run/tinyproxy/tinyproxy2.pid)

    killall -SIGTERM tail &>/dev/null
    echo "HMA proxy exited."

    # 128 + 15 (SIGTERM)
    exit 143
}
trap _trap SIGTERM SIGINT

# Default name servers to public name servers
cat /etc/resolv.google.conf > /etc/resolv.conf

# Get network addresses
networks=`ip route  | grep eth | grep "src " | awk '{print $1}' | tr '\n' ',' | sed 's/,$//'`

# Set up routing based on user
iptables -t mangle -N PROXY
iptables -t mangle -A PROXY -d ${networks} -j RETURN
iptables -t mangle -A PROXY -m owner --uid-owner proxy1 -j MARK --set-mark 1
iptables -t mangle -A PROXY -m owner --uid-owner proxy2 -j MARK --set-mark 2
iptables -t mangle -A OUTPUT -j PROXY
ip rule add fwmark 1 table proxy1
ip rule add fwmark 2 table proxy2

ip_changer_pid=0
# Start the proxy changer in background
if [ -z ${JUST_PROXY+x} ] || [ ${JUST_PROXY} -eq 0 ]; then
    echo "Starting IP changer..."
    /opt/ip-changer.sh init &
    ip_changer_pid=$!

    touch /var/log/tinyproxy/tinyproxy1.log && chown proxy1:tinyproxy /var/log/tinyproxy/tinyproxy1.log
    touch /var/log/tinyproxy/tinyproxy2.log && chown proxy2:tinyproxy /var/log/tinyproxy/tinyproxy2.log
    /usr/local/bin/python /opt/hmaproxy.py &
else
    touch /var/log/tinyproxy/tinyproxy.log && chown tinyproxy:tinyproxy /var/log/tinyproxy/tinyproxy.log
    tail -F /var/log/tinyproxy/tinyproxy.log &
    tinyproxy -c /etc/tinyproxy/tinyproxy.conf
fi
proxy_pid=$!

# Wait for proxy to stop
wait ${proxy_pid}
