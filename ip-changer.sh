#!/bin/bash

REFRESH_TEMPLATE_INTERVAL=43200
REFRESH_SERVER_LIST_INTERVAL=3600

HMA_LOG_FILE=/var/log/openvpn_hma.log
HMA_CREDENTIALS_FILE=/tmp/hmalogin

if [ -z ${HMA_COUNTRIES+x} ]; then
    # Default: european countries
    HMA_COUNTRIES="at hr cz dk fr de hu ie lu nl no pl ro sk ch gb ua it es lt se gr mt"
fi

if [ -z ${HMA_CHANGE_PROXY_INTERVAL+x} ]; then
    HMA_CHANGE_PROXY_INTERVAL=60
fi

if [ -z ${HMA_USER+x} ]; then
    # Get username from input
    read -p "- HMA! Username: " HMA_USER < /dev/tty
fi

if [ -z ${HMA_PASS+x} ]; then
    # Get password from input
    read -s -p "- HMA! Password: " HMA_PASS < /dev/tty
fi

cd "`dirname \"$0\"`"

serverList=""
count=0
function refreshServerList() {
    echo "Downloading list of servers..."
    grep=""
    for c in $HMA_COUNTRIES; do
        if [ "$grep" != "" ]; then grep="$grep\|"; fi
        grep="$grep|$c|"
    done
    curl https://securenetconnection.com/vpnconfig/servers-cli.php 2>/dev/null | grep -i -e "$grep" | grep -i -e "|udp|" > /tmp/hma-servers_ 2>/dev/null
    if [ $? -eq 0 ]; then
        serverList_=`cat /tmp/hma-servers_`
        count_=`echo "$serverList_" | wc -l`
        if [ $count_ -ge 1 ]; then
            serverList="$serverList_"
            count=$count_
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
    OIFS=$IFS; IFS=$'\n'; serverList=(${serverList}); IFS=$OIFS
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

function killProxy() {
    local pid

    # Get pid of proxy
    pid=$1; if [ "$pid" == "" ]; then pid=`pidof openvpn`; fi

    # Remove credentials file
    rm "$HMA_CREDENTIALS_FILE" &>/dev/null

    # Kill existing OpenVPN if necessery
    echo -n -e "\r"
    if [ "$pid" != "" ]; then
        echo -e "Killing existing OpenVPN(pid=$pid)..."
        kill $pid &>/dev/null
        if [ $? -ne 0 ]; then
            kill -9 $pid &>/dev/null
        fi
        echo "Killed."

        pid0=`cat /var/run/openvpn0.pid 2>/dev/null`
        pid1=`cat /var/run/openvpn1.pid 2>/dev/null`
        local lsn;
        if [ "$pid0" != "" ] && [ $pid0 -eq $pid ]; then lsn=0; fi
        if [ "$pid1" != "" ] && [ $pid1 -eq $pid ]; then lsn=1; fi
        rm "/var/run/openvpn${lsn}.pid" &>/dev/null
        rm "${HMA_LOG_FILE}_${lsn}" &>/dev/null
        touch "${HMA_LOG_FILE}_${lsn}" &>/dev/null
    fi
}

# Kill existing vpn
if [ "$1" == "kill" ]; then
    pid="$2"
    killProxy "$pid"
    exit 0
fi

defaultGw=`ip route list | grep default | awk '{print $3}'`

serverNum=0
lastServerNum=1
lastIP=""
function startNewProxy() {
    local pid
    if [ $lastServerNum -eq 0 ]; then serverNum=1; else serverNum=0; fi

    # Create credentials file
    echo -e "$HMA_USER\n$HMA_PASS" >$HMA_CREDENTIALS_FILE

    # Select random server from matched servers
    r=$(($RANDOM%$count))
    server=${serverList[r]}
    # Explode server data
    OIFS=$IFS; IFS='|'; server=(${server}); IFS=$OIFS

    if [ "$lastIP" == "${server[0]}" ]; then
        echo "Selected server is the same as last time."
    else
        echo "Selected server($serverNum, $r): ${server[1]}, ${server[0]}"

        # Create config
        conf="/tmp/hma${serverNum}.conf"
        cp /tmp/hma-template.conf $conf
        # Add a few config lines we'll need
        echo "suppress-timestamps" >> $conf
        echo "verb 0" >> $conf
        echo "log-append ${HMA_LOG_FILE}_${serverNum}" >> $conf
        echo "remote ${server[0]} 53" >> $conf
        echo "script-security 3" >> $conf
        echo "route-noexec" >> $conf
        echo "up /opt/up.sh" >> $conf
        echo "route-up /opt/route-up.sh" >> $conf

        # Add route to this host on eth0
        route add -host ${server[0]} gw ${defaultGw} &>/dev/null

        echo "Starting OpenVPN($serverNum)..."
        /usr/sbin/openvpn --daemon --writepid /var/run/openvpn${serverNum}.pid --config $conf

        if [ $? -eq 0 ]; then
            echo "OpenVPN($serverNum) has started."
            lastServerNum=$serverNum
            lastIP="${server[0]}"
        else
            echo "ERROR: OpenVPN has not started."
        fi
    fi
}

# Signal handling

function _trap() {
    if [ -f /var/run/openvpn0.pid ]; then
        pid="`cat /var/run/openvpn0.pid`"
        killProxy ${pid};
    fi
    if [ -f /var/run/openvpn1.pid ]; then
        pid="`cat /var/run/openvpn1.pid`";
        killProxy ${pid}
    fi
    # To be shure
    killall -9 openvpn &>/dev/null
    rm /var/run/openvpn0.pid &>/dev/null
    rm /var/run/openvpn1.pid &>/dev/null

    exit 143
}
trap _trap SIGINT SIGTERM

### Main cycle ###

refreshServerListCounter=$REFRESH_SERVER_LIST_INTERVAL
refreshTemplateCounter=$REFRESH_TEMPLATE_INTERVAL
changeProxyCounter=$HMA_CHANGE_PROXY_INTERVAL

while true; do
    if [ $refreshServerListCounter -ge $REFRESH_SERVER_LIST_INTERVAL ]; then
        refreshServerList
        refreshServerListCounter=0
    fi

    if [ $refreshTemplateCounter -ge $REFRESH_TEMPLATE_INTERVAL ]; then
        refreshTemplate
        refreshTemplateCounter=0
    fi

    if [ $changeProxyCounter -ge $HMA_CHANGE_PROXY_INTERVAL ]; then
        startNewProxy
        changeProxyCounter=0
    fi

    let "refreshServerListCounter=refreshServerListCounter+1"
    let "refreshTemplateCounter=refreshTemplateCounter+1"
    let "changeProxyCounter=changeProxyCounter+1"

    sleep 1
done
