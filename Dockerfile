FROM alpine:3.4
MAINTAINER Adam Wallner <wallner@bitbaro.hu>

RUN apk add --update openvpn bash curl fping squid && \
    chown -R squid:squid /var/cache/squid && \
    chown -R squid:squid /var/log/squid && \
    rm -rf /var/cache/apk/*

COPY config/squid.conf /etc/squid/squid.conf
COPY config/resolv.conf /etc/resolv.google.conf

COPY start.sh /opt/
COPY route-up.sh /opt/
COPY up.sh /opt/
COPY ip-changer.sh /opt/
COPY hma-ipcheck.sh /opt/

EXPOSE 8888

CMD ["/opt/start.sh"]
