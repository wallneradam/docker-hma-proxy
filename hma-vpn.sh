#!/bin/bash

scriptversion="2.23"

if [ $# -lt 1 ]; then
   cat <<EOF
   __ ____  ______   __  ___             _   _____  _  __
  / // /  |/  / _ | / / / _ \_______    | | / / _ \/ |/ /
 / _  / /|_/ / __ |/_/ / ___/ __/ _ \   | |/ / ___/    /
/_//_/_/  /_/_/ |_(_) /_/  /_/  \___/   |___/_/  /_/|_/

HMA! Linux CLI Script v$scriptversion - http://hmastuff.com/linux-cli

Usage:
	$0 [-c] [-d] [-l] [-p tcp|udp] [-n port] [-x] [-s] [-c id-file] [server name]

Parameters:
	-d            - daemonize - script will exit upon VPN connection
	-l            - output server list matched with the grep pattern (see examples below)
	-p tcp|udp    - sets preferred protocol, default is OpenVPN UDP
	-s            - print connection status and return exit code of 0 (connected), 1 (connecting), 2 (disconnected)
	-c id-file    - file in which your HMA! credentials are stored (optional - you will be prompted if not provided)
	                file should be: 1st line = username, 2nd line = password - file should be visible only to the current user
	-t	      - checks and shows the top 10 fastest HMA! servers by latency
	-f 	      - connects you to the fastest server based on latency (ping)
	-x            - stop the current (daemonized) HMA VPN connection
	-n port       - port number to use (default 443 for TCP, 53 for UDP)
	[server name] - this is grep pattern by which the script will filter server list (if multiple results, selects random server for connection)
	-u	      - checks version and updates this script

List servers:
	$0 -l "New York"  - lists all servers in New York
	$0 -l "|us|"      - lists all servers with US Geolocation (so incl. virtual locations)
Connect:
	$0 -p udp "|us|"  - connects to a random US-presence server using OpenVPN UDP protocol
	$0 -p tcp Texas   - connects to a random Texas server using OpenVPN TCP protocol
	$0 -n 55 Texas    - connect via port 55 to random Texas server
EOF
   exit -2
fi

cd "`dirname \"$0\"`"

SERVICE_INTERFACE=service
OPENVPN_SERVICE=openvpn
HMA_VPN_NAME=HMA
HMA_STATUS_FILE=/tmp/hma-status.txt
HMA_LOG_FILE=/tmp/hma-log.txt
#HMA_LOG_FILE=/tmp/sleeper.log

# Check what distro is installed to decide if running openvpn as service or process

distro() {
    if [[ -f /etc/redhat-release ]] ; then
        os=`cat /etc/redhat-release`
    elif [[ `which lsb_release` != "" ]] ; then
        os=$(lsb_release -s -d)
    else
        os="$(uname -s) $(uname -r) $(uname -v)"
    fi
}

# Function to check if package installed, and if not, ask if user wants to attempt installation
function checkpkg {
	if [[ $(which $1) == "" ]] ; then
		echo -n "Package '$1' not found! Attempt installation? (y/n) "
		read -n1 answer
		echo
		case $answer in
			y) $pkgmgr $1
			;;

            n)
            echo -n "Proceed anyway? (y/n) "
			read -n1 answer2
			echo
			if [[ "$answer2" == "n" ]] ; then
                exit
			fi
			;;
		esac
	fi
}

# Function to stop OpenVPN (either as service or process)

function stop_hma {
	echo "Stopping ${HMA_VPN_NAME} VPN"
	if [[ "$startas" == "service" ]] ; then
		${SERVICE_INTERFACE} ${OPENVPN_SERVICE} stop ${HMA_VPN_NAME}
	else
		# replace with pid
		killall openvpn
	fi

	local RC=$?
	if [ $RC -eq 0 ]; then
		sleep 2
	fi
	return $RC
}

# Function to clean temporary files

function cleanup {
	if [ "$TAILERPID" ]; then
		kill $TAILERPID 2> /dev/null
	fi
	unset TAILERPID
	# rm /tmp/hmalogin 2>/dev/null
	# rm /tmp/hma-config.cfg 2>/dev/null
	# rm /tmp/hma-ipcheck.sh 2>/dev/null
	# rm /tmp/hma-routeup.sh 2>/dev/null
	# rm /tmp/hma-down.sh 2>/dev/null
	rm ${HMA_STATUS_FILE} 2>/dev/null
}

# Function to clean temp. files and the log file

function full_cleanup {
	cleanup
	rm ${HMA_LOG_FILE} 2>/dev/null
}

# Function to stop OpenVPN and clean temp. files + log, then exit

function exit_hma {
	stop_hma
	local RC=$?
	full_cleanup
	exit $RC
}


# Function to execute server latency test using fping

function pingtest {
	rm /tmp/pingtest* 2> /dev/null
	echo

    # Download serverlist
    curl -s -k https://www.hidemyass.com/vpn-config/l2tp/ > /tmp/serverlist.txt

    # How many servers do we have? (line count of serverlist)
    servercount=$(wc -l /tmp/serverlist.txt | awk '{print $1}')
    i=1

    while read line; do
    	# Extract server IP and name from each line of the list
    	serverip=$(echo $line | awk '{print $1}')
    	servername=$(echo $line | awk '{$1="";print $0}')
    	# Parse the average latency result for each server
    	avg=$(fping -B 1.0 -t 300 -i 1 -r 0 -e -c 1 -q $serverip 2>&1 | awk -F'/' '{print $8}')
    	# Save the servername and average latency to temp. result file
    	echo "$servername = $avg" >> /tmp/pingtest.txt

    	# Calculate percentage of how far we're done with testing
    	percentage=$((($i*100)/$servercount));
    	echo -ne "Testing all servers for latency using fping ($i \ $servercount) $percentage %  \033[0K\r"

    	# How many servers have we tested so far?
    	i=$((i+1))
    done < /tmp/serverlist.txt

    # Sort the latency test results by latency, save to 2nd temp file
    cat /tmp/pingtest.txt | awk -F[=] '{ t=$1;$1=$2;$2=t;print; }' | sort -n > /tmp/pingtest.txt.2

    # Get rid of lines that don't contain a latency value, save rest to final result file
    while read line; do
    	firstcol=$(echo $line | awk '{print $1}')
    	re='^[0-9]+([.][0-9]+)?$'

    	if [[ $firstcol =~ $re ]] ; then
    		echo $line >> /tmp/pingtest.best.txt
    	fi
    done < /tmp/pingtest.txt.2

    echo

    # Print top 10 servers based on latency IF we're just supposed to test
    if [[ ! "$1" == "connect" ]] ; then
    	echo
    	echo "Top 10 Servers by latency (ping)"
    	echo "================================"
    	cat /tmp/pingtest.best.txt | sort -n | head -10
    	echo
    	exit
    	else
    	# Set best server as connect target for VPN connection process if we're supposed to do that
    	fastestserver=""
    	fastestserver=$(cat /tmp/pingtest.best.txt | head -1 | awk '{$1="";print}' | sed -e 's/^[[:space:]]*//')
    	grep=$fastestserver
    	echo "Fastest server: $fastestserver"
    	echo
    fi
}

# Function to print connection status of OpenVPN
function print_status {
	local STATUS=2
	if [ -f ${HMA_STATUS_FILE} ]; then
		local count=0
		while read line; do
			echo "$line"
			if [ $count -eq 0 ]; then
				echo "$line" | grep -qi "^CONNECTED"
				local RC=$?
				if [ $RC -eq 0 ]; then
					STATUS=0
				else
					echo "$line" | grep -qi "^CONNECTING"
					RC=$?
					if [ $RC -eq 0 ]; then
						STATUS=1
					fi
				fi
				count=1
			fi
		done < $HMA_STATUS_FILE
	else
		echo "Disconnected"
	fi
	return $STATUS
}

# Function to check if new version is available and if so, update
function updatenow {
	echo -e "\n[ HMA! Linux CLI Script v$scriptversion - http://hmastuff.com/linux-cli ]\n\nChecking for new version..."
 	rm /tmp/hma-vpn.sh 2> /dev/null
	curl -s -k https://hmastuff.com/linux/hma-vpn.sh > /tmp/hma-vpn.sh
    if [[ -f "/tmp/hma-vpn.sh" ]] ; then
		# Extract version number from top of script
                updateversion=$(grep -m 1 'scriptversion=' /tmp/hma-vpn.sh | awk -F'\042' '$0=$2')
		# If that failed, update must have failed, so tell user that and exit
		if [[ "$updateversion" = "" ]] ; then
			echo -e "Unable to check for new version.\nPlease check your internet connectivity or try again later.\n"
			exit 1
		fi
	    # If scriptversion is lower than hosted scriptversion, replace script
        if [[ $scriptversion < $updateversion ]] ; then
            echo "Updating v$scriptversion to v$updateversion ... "
            chmod +x /tmp/hma-vpn.sh && mv /tmp/hma-vpn.sh .
            echo "Done!"
        else
            echo -e "Already latest version. (v$scriptversion)\n"
        fi
    fi
    exit 0
 }

# Check which package manager to use, apt-get or yum. If both avail., use apt-get
pkgmgr=""
if [[ ! $(which yum) == "" ]] ; then
	pkgmgr="yum install"
fi
if [[ ! $(which apt-get) == "" ]] ; then
	pkgmgr="apt-get install"
fi

# Check for needed packages and offer installation
checkpkg curl
checkpkg fping
checkpkg openvpn

# If curl not available, use wget
curl=`which curl`
curl="$curl -k --connect-timeout 5 -s"

# In case /usr/sbin is not in path env, add it, so we can run OpenVPN as process
if [[ $PATH != *"/usr/sbin"* ]]; then PATH=$PATH:/usr/sbin ; fi

openvpn=`which openvpn`
port=
proto=
authfile=
list=0
stopvpn=0
printstatus=0
asdaemon=0

# Check for what parameter script was run with and act accordingly
while getopts "ftduslxp:c:n:" parm
do
	case $parm in
	t)	pingtest
		;;
	f)      pingtest connect
		;;
	s)
		printstatus=1
		;;
	d)
		asdaemon=1
		;;
	n)
		port="$OPTARG"
		;;
	x)
		stopvpn=1
		;;
	l)
		list=1
		;;
	u)	updatenow
		;;
	p)
		proto="$OPTARG"
		;;
	c)
		authfile=`readlink -m "$OPTARG"`
		;;
	?)	echo "unknown $parm / $OPTARG"
	esac
done

# Script run with -x ? THen stop OpenVPN and clean temp. files and exit
if [ $stopvpn -eq 1 ]; then
	stop_hma
	cleanup
	exit 0
# Script run with with -s ? Then print connection status and exit
elif [ $printstatus -eq 1 ]; then
	print_status
	RC=$?
	exit $RC
fi

# Script run with -d but credential file not specified (-c)? Advise and exit
if [ $asdaemon -eq 1 -a -z "$authfile" ]; then
	echo "You must specify a credentials file (the -c option) when using the -d option"
	echo "Create a file with your username as 1st line, password as 2nd line."
	echo "e.g. echo MyUsername > /tmp/vpnlogin && echo MyPassword >> /tmp/vpnlogin"
	echo "Then connect like this: $0 -c /tmp/vpnlogin -d Texas"
	exit 4

fi

# Script run with -c but credentials file doesn't exit? Advise and exit
if [ "$authfile" -a ! -r "$authfile" ]; then
	echo "Credentials file '$authfile' does not exist or is not readable"
	exit 5
fi

shift $(( $OPTIND - 1 ))
grep="$*"

# If we did a latency test, use fastest server as VPN connection target
if [[ ! "$fastestserver" == "" ]] ; then
	grep="$fastestserver"
fi

names=( )
locations=( )
ips=( )
tcps=( )
udps=( )
count=0
full_cleanup

# Download serverlist
echo -n "Obtaining list of servers..."
$curl https://securenetconnection.com/vpnconfig/servers-cli.php 2>/dev/null| grep -i -e "$grep" | grep -i -e "$proto" > /tmp/hma-servers
echo " OK."
exec < /tmp/hma-servers

# If serverlist empty
if [[ "$(cat /tmp/hma-servers)" == "" ]]; then
    if [[ "$($curl https://securenetconnection.com/vpnconfig/servers-cli.php)" == "" ]] ; then
    	echo "Unable to fetch serverlist!"
    	echo "Please check your internet connection!"
    	exit
    fi
fi

# rm /tmp/hma-servers

while read server
do
	: $(( count++ ))
	ips[$count]=`echo "$server"|cut -d '|' -f 1`
	udps[$count]=`echo "$server"|cut -d '|' -f 5`
	locations[$count]=`echo "$server"|cut -d '|' -f 3`
	tcps[$count]=`echo "$server"|cut -d '|' -f 4`
	names[$count]=`echo "$server"|cut -d '|' -f 2`
done

# No server matching grep pattern? Advise and exit; otherwise print match count
if [ "$count" -lt 1 ] ; then
	echo "No matching servers to connect: $grep"
	exit
else
	echo "$count servers matched"
fi

if [ $list -eq 1 ]; then
	for i in `seq 1 $count`; do
		echo -e "${ips[$i]}\t${tcps[$i]}\t${udps[$i]}\t(${locations[$i]}) ${names[$i]}"
	done
	exit
fi

# Select random server from matched servers
i=$(( $RANDOM%$count + 1 ))
SERVER="${names[$i]} ${ips[$i]}"
echo "Selected Server:"
echo -e $SERVER

# If protocol wasn't specified, use UDP
if [ "$proto" == "" ]; then
	if [ "$udps[$i]" != "" ]; then
		proto=udp
	else
		proto=tcp
	fi
fi

if [ "$port" == "" ]; then
        if [ "$proto" == "tcp" ]; then
        port=443
        else
        port=53
        fi
fi

echo "Loading configuration..."	#

# Download *.ovpn template to temp file - silently
$curl "https://securenetconnection.com/vpnconfig/openvpn-template.ovpn" > /tmp/hma-config.cfg 2>/dev/null

# Add a few config lines we'll need
echo "suppress-timestamps" >> /tmp/hma-config.cfg
echo "verb 0" >> /tmp/hma-config.cfg
echo "log-append ${HMA_LOG_FILE}" >> /tmp/hma-config.cfg
echo "remote ${ips[$i]} $port" >> /tmp/hma-config.cfg
echo "proto $proto" >> /tmp/hma-config.cfg
echo "route-up /tmp/hma-routeup.sh" >> /tmp/hma-config.cfg
echo "down /tmp/hma-down.sh" >> /tmp/hma-config.cfg
echo "script-security 3" >> /tmp/hma-config.cfg

# If credentials file was specified, add location to config file
if [ "$authfile" ]; then
	echo "auth-user-pass $authfile" >> /tmp/hma-config.cfg
else
# Addition to bypass failure to read from stdin(systemd-tty-ask-password-agent issue)
# Ask for user+pass, save it, tell config file to get 'em from there
	read -p "- HMA! Username: " vpnuser < /dev/tty
	echo $vpnuser > /tmp/hmalogin
	read -s -p "- HMA! Password: " vpnpass < /dev/tty
	echo $vpnpass >> /tmp/hmalogin
	vpnuser=
	vpnpass=
	echo "auth-user-pass /tmp/hmalogin" >> /tmp/hma-config.cfg
fi

# To start OpenVPN as service, config file needs to be in /etc/openvpn/ - so link it from there to temp
if [ ! -f /etc/openvpn/${HMA_VPN_NAME}.conf ]; then
cat <<EOF | tee /etc/openvpn/${HMA_VPN_NAME}.conf > /dev/null
config /tmp/hma-config.cfg
EOF
fi

# Create script to run upon successful VPN connection
cat <<EOF > /tmp/hma-routeup.sh
#!/bin/sh
echo "Connected to \"$SERVER\" ($proto/$port)" > ${HMA_STATUS_FILE}
#nohup /tmp/hma-ipcheck.sh >/dev/null 2>&1 &
nohup /tmp/hma-ipcheck.sh &
# rm /tmp/hma-routeup.sh
EOF

# Create script to run upon disconnecting from VPN
cat <<EOF > /tmp/hma-down.sh
#!/bin/sh
	rm /tmp/hmalogin 2>/dev/null
	rm /tmp/hma-config.cfg 2>/dev/null
	rm /tmp/hma-ipcheck.sh 2>/dev/null
	# rm /tmp/hma-routeup.sh 2>/dev/null
	# rm ${HMA_STATUS_FILE} 2>/dev/null
	rm /tmp/hma-down.sh 2>/dev/null
EOF

# Create script to check for IP
cat <<EOF > /tmp/hma-ipcheck.sh
#!/bin/bash
ip=""
attempt=0
while [ "\$attempt" -lt "3" ]; do
	attempt=\$((\$attempt+1))
	sleep 1
	if [[ "\$ip" == "" ]] ; then
	ip=\$($curl --connect-timeout 10 --max-time 10 geoip.hmageo.com/ip/ 2>/dev/null)
	fi
	if [[ "\$ip" == "" ]] ; then
	sleep 1
	ip=\$($curl --connect-timeout 10 --max-time 10 icanhazip.com 2>/dev/null)
	fi
	if [[ "\$ip" == "" ]] ; then
	sleep 1
	ip=\$($curl --connect-timeout 10 --max-time 10 ipecho.net/plain 2>/dev/null)
	else
	attempt=3
	fi
done

if [[ "\$ip" == "" ]] ; then
	echo "Failed to check IP address."
else
	echo "Your IP is \$ip"
fi
EOF

# Ensure scripts are accessible and executable
chmod 755 /tmp/hma-ipcheck.sh
chmod 755 /tmp/hma-routeup.sh
chmod 755 /tmp/hma-down.sh

echo "Connecting to \"$SERVER\" ($proto/$port)" > ${HMA_STATUS_FILE}
echo "" > ${HMA_LOG_FILE}

if [ $asdaemon -eq 0 ]; then
	( tail -f ${HMA_LOG_FILE} 2>/dev/null | sed -e '/^WARNING:/ d' -e '/^NOTE:/ d' ) &
	TAILERPID=$!
fi

# Check for what distro is being used
distro
echo
echo "Detected distro: $os"
echo

# If Debian or Ubuntu, run OpenVPN as service
if [[ "$os" == *"Debian"* ]] || [[ "$os" == *"Ubuntu"* ]]; then
	echo "Calling OpenVPN as service..."
	startas="service"
	${SERVICE_INTERFACE} ${OPENVPN_SERVICE} start ${HMA_VPN_NAME} > /dev/null
# Otherwise run OpenVPN as process
else
# elif [[ "$os" == *"CentOS"* ]] || [[ "$os" == *"Fedora"* ]]; then
	echo "Calling OpenVPN as process..."
	startas="process"
	$openvpn --daemon --config /etc/openvpn/${HMA_VPN_NAME}.conf
fi

# If OpenVPN exit code isn't 0, connection must have failed. Clean temp files and exit
RC=$?
if [ $RC -gt 0 ]; then
	echo "Connecting to \"$SERVER\" failed"
	cleanup
	exit $RC
fi

if [ $asdaemon -eq 0 ]; then
	trap exit_hma SIGINT SIGTERM
	print_status
	RC=$?
	if [ $RC != 0 ]; then
		echo "Enter CTRL-C to terminate connection"
		echo "Waiting for connection to complete..."
		while [ $RC != 0 ]; do
			sleep 5
			print_status > /dev/null
			RC=$?
		done
		print_status
	fi
	while true; do
		read dummy
	done
else
	print_status
	echo "  to see status use \"$0 -s\""
	echo "  to disconnect use \"$0 -x\""
fi
