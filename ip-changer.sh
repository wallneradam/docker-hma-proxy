#!/bin/bash

REFRESH_TEMPLATE_INTERVAL=43200
REFRESH_SERVER_LIST_INTERVAL=3600

HMA_LOG_FILE=/var/log/openvpn_hma.log
HMA_CREDENTIALS_FILE=/tmp/hmalogin

cd "`dirname \"$0\"`"

serverList=()
count=0
function refreshServerList() {
    echo "Downloading list of servers..."
    grep=""
    for c in ${HMA_COUNTRIES}; do
        if [ "$grep" != "" ]; then grep="$grep\|"; fi
        grep="$grep\|$c\|"
    done
    curl https://securenetconnection.com/vpnconfig/servers-cli.php 2>/dev/null | grep -i -e "$grep" | grep -i -e "\|udp\|" > /tmp/hma-servers_ 2>/dev/null
    if [ $? -eq 0 ]; then
        serverList_=`cat /tmp/hma-servers_`
        count_=`echo "$serverList_" | wc -l`
        if [ ${count_} -ge 1 ]; then
            serverList="$serverList_"
            count=${count_}
            mv /tmp/hma-servers_ /tmp/hma-servers
        fi
        serverList_=""
        count_=""
    else
        echo "Error: Servers could not been downloaded."
        serverList=`cat /tmp/hma-servers`
        count=`echo "$serverList" | wc -l`
    fi
    serverList_=""
    count_=""
    # Explode
    OIFS=$IFS; IFS=$'\n'; serverList=(${serverList}); IFS=${OIFS}
    echo "List of servers are ready, found $count servers."
}

function refreshTemplate() {
    echo "Downloading OpenVPN config template..."
    curl -s "https://securenetconnection.com/vpnconfig/openvpn-template.ovpn" | \
        grep -v "auth-user-pass"  > /tmp/hma-template_.conf

    if [ $? -eq 0 ]; then
        mv /tmp/hma-template_.conf /tmp/hma-template.conf
        echo "proto udp" >> /tmp/hma-template.conf
        echo "port 53" >> /tmp/hma-template.conf
        echo "auth-user-pass ${HMA_CREDENTIALS_FILE}" >> /tmp/hma-template.conf
        echo "auth-nocache" >> /tmp/hma-template.conf

        echo "OpenVPN config template is downloaded."
    else
        echo "ERROR: template couldn't been downloaded!"
    fi
}

function killVPN() {
    local vpnNum=$1
    # Kill existing OpenVPN if necessery
    if [ "$vpnNum" != "" ]; then
        # Remove credentials file
        rm "$HMA_CREDENTIALS_FILE" &>/dev/null

        pid=`cat /var/run/openvpn${vpnNum}.pid 2>/dev/null`
        # Kill process
        kill ${pid} &>/dev/null
        # Wait for process exiting
        retry=50; while kill -s 0 ${pid} &>/dev/null; do sleep 0.1; let retry=retry-1; [ ${retry} -le 0 ] && break; done
        # Force kill if still running
        kill -9 ${pid} &>/dev/null

        rm "/var/run/openvpn${vpnNum}.pid" &>/dev/null
        rm "${HMA_LOG_FILE}_${vpnNum}" &>/dev/null
        touch "${HMA_LOG_FILE}_${vpnNum}" &>/dev/null
    fi
}


defaultGw=`ip route list | grep default | awk '{print $3}'`
lastIP1=""; lastIP2=""
function startNewVPN() {
    local pid
    local serverNum=$1

    # Create credentials file
    echo -e "$HMA_USER\n$HMA_PASS" >${HMA_CREDENTIALS_FILE}
    chmod 0600 ${HMA_CREDENTIALS_FILE}

    # Select random server from matched servers
    eval "newIp=\"${lastIP1}\""
    server=""
    random=0
    while [ "$lastIP1" == "$newIp" ] || [ "$lastIP2" == "$newIp" ]; do
        random=$(($RANDOM%$count))
        server=${serverList[random]}
        # Explode server data
        OIFS=$IFS; IFS='|'; server=(${server}); IFS=${OIFS}
        newIp="${server[0]}"
    done

    echo "Selected server($serverNum, $random): ${server[1]}, ${server[0]}"

    # Create config
    conf="/tmp/hma${serverNum}.conf"
    cp /tmp/hma-template.conf ${conf}
    # Add a few config lines we'll need
    echo "suppress-timestamps" >> ${conf}
    echo "verb 0" >> ${conf}
    echo "log-append ${HMA_LOG_FILE}_${serverNum}" >> ${conf}
    echo "remote ${server[0]} 53" >> ${conf}
    echo "script-security 3" >> ${conf}
    echo "route-noexec" >> ${conf}
    echo "up /opt/up.sh" >> ${conf}
    echo "route-up /opt/route-up.sh" >> ${conf}
    echo "down /opt/down.sh" >> ${conf}
    echo "dev tun$serverNum" >> ${conf}

    # Add route to this host on eth0
    route add -host ${server[0]} gw ${defaultGw} &>/dev/null

    echo "Starting OpenVPN($serverNum)..."
    /usr/sbin/openvpn --daemon --writepid /var/run/openvpn${serverNum}.pid --config ${conf}

    if [ $? -eq 0 ]; then
        echo "OpenVPN($serverNum) has started."
        eval "lastIP${serverNum}=\"${server[0]}\""
    else
        echo "ERROR: OpenVPN has not started." >&2
    fi
}


if [ -z ${HMA_COUNTRIES+x} ]; then
    # Default: european countries
    HMA_COUNTRIES="at hr cz dk fr de hu ie lu nl no pl ro sk ch gb ua it es lt se gr mt"
fi

if [ -z ${HMA_USER+x} ]; then
    # Get username from input
    read -p "- HMA! Username: " HMA_USER < /dev/tty
fi

if [ -z ${HMA_PASS+x} ]; then
    # Get password from input
    read -s -p "- HMA! Password: " HMA_PASS < /dev/tty
fi


command="$1"

# Kill existing vpn
if [ "$command" == "kill" ]; then
    vpnNum="$2"
    if [ "$vpnNum" == "all" ]; then
        killVPN 1
        killVPN 2
    else
        killVPN "$vpnNum"
    fi

    exit 0
fi

# Restart vpn by sending signal to the init process
if [ "$command" == "change" ]; then
    eval "kill -SIGUSR$2 `pgrep -f \"$0\" -o`"
    exit 0
fi

if [ "$command" != "init" ]; then
    echo "Unknown command: $command !" >&2
    exit 1
fi


# Signal handling

function _trap() {
    if [ -f /var/run/openvpn1.pid ]; then killVPN 1; fi
    if [ -f /var/run/openvpn2.pid ]; then killVPN 2; fi
    # To be sure
    killall -9 openvpn &>/dev/null
    exit 143
}
trap _trap SIGINT SIGTERM

### VPN change by signal

function _changeVPN1() {
    killVPN 1
    startNewVPN 1
}

function _changeVPN2() {
    killVPN 2
    startNewVPN 2
}
trap _changeVPN1 SIGUSR1
trap _changeVPN2 SIGUSR2

### Main cycle ###

# Start initial VPN's
killall -9 openvpn &>/dev/null

# Start initial VPNs
refreshServerList
refreshTemplate
startNewVPN 1
startNewVPN 2

refreshServerListCounter=0
refreshTemplateCounter=0

# Refresh template and server list
while true; do
    if [ ${refreshServerListCounter} -ge ${REFRESH_SERVER_LIST_INTERVAL} ]; then
        refreshServerList
        refreshServerListCounter=0
    fi

    if [ ${refreshTemplateCounter} -ge ${REFRESH_TEMPLATE_INTERVAL} ]; then
        refreshTemplate
        refreshTemplateCounter=0
    fi

    let "refreshServerListCounter=refreshServerListCounter+1"
    let "refreshTemplateCounter=refreshTemplateCounter+1"

    sleep 1
done
