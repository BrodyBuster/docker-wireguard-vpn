#!/bin/bash
## Set variables
# Name of the docker network to route through wireguard
# This network will be created if it does not exist using 10.30.0.0/16
docker_net_name="docker-vpn0"
# Name of wireguard interface to create
dev_name="wg0"
# Dedicated Torguard ip. Leave empty if not using dedicated_ip=""
dedicated_ip="1.2.3.4"
# email to send notifications to. Leave empty if not using mailto=""
mailto="user@email.org"
##########################################################################################
# Get ip addresses and subnets needed
docker_net=$(docker network inspect $docker_net_name | grep Subnet | awk '{print $2}' | sed 's/[",]//g')
interface_ip=$(grep Address /etc/wireguard/$dev_name.conf | awk '{print $3}' | cut -d/ -f1)

if_check () {
eval "$1"  > /dev/null 2>&1
eval "$2"
RETVAL=$?
if [ $RETVAL -ne 0 ]; then
  echo "[FAIL]"
  exit 1
fi
echo "[ OK ]     $3"
}

while_check () {
eval "$2"
RETVAL=$?
while [ $RETVAL -ne 0 ]; do
  eval "$1" > /dev/null 2>&1
  echo "[INFO]     Route/Rule/Network Does Not Exist. Creating ..."
  RETVAL=$?
done
echo "[ OK ]     $3"
}

status () {
# set vpnstatus file
containers=$(docker network inspect $docker_net_name -f '{{ range $value := .Containers }}{{printf  "%s " .Name}}{{ end }}')
vpnstatus="/tmp/vpnstatus.tmp"
test -f $vpnstatus || echo "600" > $vpnstatus

# Check to see if using DEDICATED ip
if [ -z "$dedicated_ip" ]; then
  endpoint_ip=$(grep Endpoint /etc/wireguard/$dev_name.conf | awk '{print $3}' | cut -d: -f1)
else
  endpoint_ip=$dedicated_ip
fi
printf "[INFO]     Checking VPN Status":
vpn_ip=$(docker run --rm --net=$docker_net_name curlimages/curl --connect-timeout 10 --silent ifconfig.me/ip)
ip=$(curl --silent https://api.ipify.org)

if [[ $vpn_ip == $endpoint_ip ]]; then
  echo " UP"
  message="`date`: VPN Status: UP"
  subject="VPN STATUS: UP"
  RETVAL="0"
elif [[ $vpn_ip == $ip ]]; then
  echo " WARNING!! VPN DOWN - KILL SWITCH DOWN WARNING!!"
  message="`date`: VPN Status: WARNING!! VPN DOWN - KILL SWITCH DOWN WARNING!!"
  subject="VPN STATUS: WARNING"
  docker stop $containers
  RETVAL="255"
else
  echo " DOWN"
  message="`date`: VPN Status: DOWN"
  subject="VPN STATUS: DOWN"
  RETVAL="254"
fi

#send notification
if [ ! -z "$mailto" ]; then
  RETVAL_PREVIOUS=$(< $vpnstatus)
  if [[ $RETVAL -ne $RETVAL_PREVIOUS ]]; then
    echo "$message" | mail -s "$subject" $mailto
  fi
fi

echo $RETVAL > $vpnstatus
}

up (){
# check for conf file
if [ ! -f "/etc/wireguard/$dev_name.conf" ]; then
  echo -e "failed: no conf file found in/etc/wireguard"
  exit 1
fi
echo -e "[ OK ]     conf file exists"

# add wireguard interface
cmd='ip link add $dev_name type wireguard'
check='ip addr | grep $dev_name > /dev/null 2>&1'
message=$(eval echo "$cmd")
if_check "$cmd" "$check" "$message"

# set wireguard conf
cmd='wg setconf $dev_name /etc/wireguard/$dev_name.conf'
check='wg showconf $dev_name > /dev/null 2>&1'
message=$(eval echo "$cmd")
if_check "$cmd" "$check" "$message"

# assign ip to wireguard interface
cmd='ip addr add $interface_ip dev $dev_name'
check='ip addr | grep "$interface_ip" > /dev/null 2>&1'
message=$(eval echo "$cmd")
if_check "$cmd" "$check" "$message"

# set sysctl
cmd="sysctl -w net.ipv4.conf.all.rp_filter=2"
echo "[ OK ]     $cmd"

# set mtu for wireguard interface
cmd="ip link set mtu 1420 up dev $dev_name"
echo "[ OK ]     $cmd"

# bring wireguard interface up
cmd='ip link set up dev $dev_name'
check='ip addr | grep $dev_name | grep UP > /dev/null 2>&1'
message=$(eval echo "$cmd")
if_check "$cmd" "$check" "$message"

# create docker network
cmd='docker network create $docker_net_name --subnet 10.30.0.0/16 -o "com.docker.network.driver.mtu"="1420"'
check='docker network inspect $docker_net_name > /dev/null 2>&1'
message=$(eval echo "$cmd")
while_check "$cmd" "$check" "$message"

# add table 200
cmd='ip rule add from $docker_net table 200'
check='ip rule show | grep -w "lookup 200" > /dev/null 2>&1'
message=$(eval echo "$cmd")
while_check "$cmd" "$check" "$message"

# add blackhole
cmd='ip route add blackhole default metric 3 table 200'
check='ip route show table 200 2>/dev/null | grep -w "blackhole" > /dev/null 2>&1'
message=$(eval echo "$cmd")
while_check "$cmd" "$check" "$message"

# add default route for table 200
cmd='ip route add default via $interface_ip metric 2 table 200'
check='ip route show table 200 2>/dev/null | grep -w "$interface_ip" > /dev/null 2>&1'
message=$(eval echo "$cmd")
while_check "$cmd" "$check" "$message"

# add local lan route
cmd='ip rule add table main suppress_prefixlength 0'
check='ip rule show | grep -w "suppress_prefixlength" > /dev/null 2>&1'
message=$(eval echo "$cmd")
while_check "$cmd" "$check" "$message"

#check VPN status
status
}

down (){
# del wireguard interface
cmd='ip link del $dev_name'
message=$(eval echo "$cmd")
if_check "$cmd" "$check" "$message"

# add table 200
cmd='ip rule add from $docker_net table 200'
check='ip rule show | grep -w "lookup 200" > /dev/null 2>&1'
message=$(eval echo "$cmd")
while_check "$cmd" "$check" "$message"

# add blackhole
cmd='ip route add blackhole default metric 3 table 200'
check='ip route show table 200 2>/dev/null | grep -w "blackhole" > /dev/null 2>&1'
message=$(eval echo "$cmd")
while_check "$cmd" "$check" "$message"

#check VPN status
status
}

command="$1"
shift

case "$command" in
  up) up "$@" ;;
  down) down "$@" ;;
  status) status "$@" ;;
  *) echo "Usage: $0 up|down|status" >&2; exit 1 ;;
esac
