# docker-hma-proxy
Hide My Ass + Squid Docker image

It is a Hide My Ass powered proxy server based on Alpine Linux. It uses Squid as a proxy. Connects to a random HMA server with OpenVPN.

You need HMA account for this to work, and must be started as privileged container (because of OpenVPN).

Features:

- Gives new IP address after a specified amount of time
- Automatically downloads and updates HMA servers
- Login with the specified account (by environment variables)
- Listen to (forward) proxy requests on port 8888
- Starts 2nd OpenVPN session while the other still communicates, makes immediate IP switching possible
- Filter servers by countries

Usage:
    `docker run -ti --name hma --env-file $PWD/hma1.env --privileged --rm -p 8888:8888 pickapp/hma-proxy:1.1`

Where hma1.env contains something similar:
```
HMA_USER=User
HMA_PASS=Password
HMA_COUNTRIES="at hr cz hu ro sk ua pl"
HMA_CHANGE_PROXY_INTERVAL=60
```
