#!/bin/bash

# Handle signals
function _trap() {
    echo "Killing HMA proxy..."
    if [ ${ip_changer_pid} -ne 0 ]; then kill -SIGTERM ${ip_changer_pid} &>/dev/null; wait ${ip_changer_pid}; fi
    if [ ${squid_pid} -ne 0 ]; then kill -SIGTERM ${squid_pid} &>/dev/null; wait ${squid_pid}; fi
    killall -SIGTERM tail &>/dev/null
    kill -SIGTERM ${logrotate_pid} &>/dev/null
    echo "HMA proxy exited."
    # 128 + 15 (SIGTERM)
    exit 143
}
trap _trap SIGTERM SIGINT

# Default name servers to google name servers
cat /etc/resolv.google.conf > /etc/resolv.conf

# Start the proxy changer in background
echo "Starting IP changer..."
/opt/ip-changer.sh &
ip_changer_pid=$!

# Logging
tail -F /var/log/squid/cache.log 2>/dev/null &
tail -F /var/log/squid/access.log 2>/dev/null &

# Create cache directories
echo "Initializing Squid cache..."
squid -Nz

# Launch squid
echo "Starting Squid..."
squid -YCdD
squid_pid=$!
echo "OK"
# Rotate logs ~horly
(while true; do sleep 3600; squid -k rotate; done) &
logrotate_pid=$!

# Wait for IP changer to stop
wait ${ip_changer_pid}
# Wait for squid to stop
wait ${squid_pid}
