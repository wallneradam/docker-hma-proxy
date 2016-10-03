# docker-hma-proxy
Hide My Ass + Proxy Docker Image

It is a Hide My Ass powered proxy server based on Alpine Linux. It connects to a random HMA server with OpenVPN.
It uses 2 OpenVPN connections and change servers regularly on a specified timeout. Both of the onnections are used
by their own TinyProxy servers, and there is a Proxy written in python which uses both TinyProxy servers in 
parallel. The result of the python proxy will be the result of the fastest HMA server (and TinyProxy).
If a server is not responding, the python proxy tries to start another HMA VPN. This way continuous and relatively
fast connections are posible. 

You need HMA account for this to work, and must be started as privileged container (because OpenVPN needs it).

Features:

- Gives new IP address after a specified amount of time
- Automatically downloads and updates HMA servers
- Login with the specified account (by environment variables)
- Listen to (forward) proxy requests on port 8888
- Usees 2 OpenVPN connections at the same time to make it more fast and reliable
- Filter servers by countries

Usage:
    `docker run -ti --name hma --env-file $PWD/config/hma.env --privileged --rm -p 8888:8888 pickapp/hma-proxy:1.2`

Where hma.env contains something similar:
```
HMA_USER=User
HMA_PASS=Password
HMA_COUNTRIES="at hr cz hu ro sk ua pl"
HMA_CHANGE_IP_INTERVAL=60
```
