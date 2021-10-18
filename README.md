# docker-wireguard-vpn

A bash script that will create a docker network (default name is docker-vpn0) and tunnel it's traffic through a wireguard tunnel. All other traffic from the host will be routed outside the tunnel. 

Useful for placing your torrent docker behind a vpn, without having all other traffic pushed through the tunnel. The script leverages ip routes and rules the tunnel the traffic, as well as setting a blackhole route to keep traffic from the docker network from escaping if the tunnel goes down.

# Scope

I've been on a mission to get Wireguard to work properly with containers for some time now. I was excited when I saw that it was touted as namespace and container friendly, and that it would be a cinch to get it to incorporate into my already existing docker stacks.

Not so fast though, there were limitations ...

My first attempt was using namespaces per the Wireguard docs. Create the interface on the host and move it into its own namespace. Completely isolated from the host. The only route in that namespace would be the Wireguard interface. Perfect! It wouldn't require any iptables kill switch then. Unfortunately there is no permanent way to connect the Wireguard namespace to the docker network namespace, because every time a container is created or recreated, it deletes the network namespace. And since the only way to access the namespace from the host in the containers is by linking them, every time a container is restarted it would need to be relinked. Not a set it and forget it kind of solution.

OK ... so then I decided why not try Wireguard IN a container and run all my other containers through that? Same problem. If the Wireguard container gets restarted all connections to the dependent containers get cut, and the only way to reconnect is to restart the entire dependent stack. Also not a good set it and forget it solution.

So I finally settled on running the Wireguard interface on the host. I decided not to use wg-quick, as its default policy is to route ALL local traffic through the tunnel. I wanted a split tunnel to only send some packets through the vpn, regardless of destination.

My solution was to use wg and a docker bridge network specifically created for the vpn. Then create a set of routes to route that docker network, and that network only, through the tunnel. Unfortunately with this solution, if the Wireguard interface goes down, the vpn docker network would get routed through the main intertface again. This is because the new route that was created, will get deleted when its gateway is no longer available. The result? The main intertface would become the default route, not the Wireguard interface. Not good. I needed a persistent kill switch. 

All of this is solved using some simple routes and metrics, that I put together as a bash script.


# Prerequisites 
1. Docker
2. Wireguard Module installed on host

# Installation:
1. Save script to to /usr/local/bin/
2. Make sure it's executable (chmod +x)
3. Create a wireguard conf file and save to /etc/wireguard/wg0.conf (see example)
4. Edit wireguard.sh and change the variables to your liking. If you are using a dedicated IP from your vpn provider, assign it to the DEDICATED_IP varialble, otherwise leave it as is. 

```
## Set variables
# Name of the docker network to route through wireguard
# This network will be created if it does not exist using 10.30.0.0/16
DOCKER_NET_NAME="docker-vpn0"
# Name of wireguard interface to create
DEV_NAME="wg0"
# Dedicated IP assigned by your VPN provider. Leave as is, if you're not using a dedicated IP
DEDICATED_IP=""
```

# Example /etc/wireguard/wg0.conf

This script uses wg and not wg-quick to create the interface. wg uses a differently formated conf file than wg-quick.
Example of conf file for this script (notice that DNS and Address are commented out):
```
[Interface]
PrivateKey = [pubkey]
ListenPort = 51820
#DNS = [dns]
#Address = [address]/24

[Peer]
PublicKey = [pubkey]
AllowedIPs = 0.0.0.0/0
Endpoint = [endpoint ip]
PersistentKeepalive = 25
```
# Cron to launch at boot

In order to bring this wireguard interface at boot, create a cron job as root using crontab -e, and add the following entry using the path to the wireguard script
```
@reboot         /usr/local/bin/wireguard up
```

# Example docker-compose
```
transmission:
    image: linuxserver/transmission
    container_name: transmission
    environment:
      - PUID=1001
      - PGID=1001
      - TZ=America/New_York
      - TRANSMISSION_WEB_HOME=/combustion-release/
    volumes:
      - [volume]
      - [volume]
      - [volume]
      - [volume]      
      - [volume]
    ports:
      - 9091:9091 # GUI
      - 51413:51413 # only needed if you have port forwarded on your vpn
      - 51413:51413/udp # only needed if you have port forwarded on your vpn
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
    networks:
      - vpn
           

networks:
  vpn:
    external:
      name: docker-vpn0
```
# Usage
Bring the wirguard interface up and create all the ip rules and routes
```
$ wireguard up
```
Bring the wirguard interface down and make sure the blackhole route is valid
```
$ wireguard down
```
Check the status of the wireguard vpn
```
$ wireguard status
```
