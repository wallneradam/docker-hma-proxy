FROM python:2.7-alpine
MAINTAINER Adam Wallner <wallner@bitbaro.hu>

RUN apk add --update openvpn bash curl tinyproxy && \
    rm -rf /var/cache/apk/* && \
    adduser -S -D -H -u 501 -G tinyproxy -g "Proxy1" proxy1 && \
    adduser -S -D -H -u 502 -G tinyproxy -g "Proxy2" proxy2 && \
    chmod g+w /var/run/tinyproxy/ && \
    chmod g+w /var/log/tinyproxy/

COPY config/resolv.conf /etc/resolv.google.conf
COPY config/rt_tables /etc/iproute2/rt_tables
COPY *.py /opt/
COPY *.sh /opt/
COPY config/tinyproxy* /etc/tinyproxy/

EXPOSE 8888

CMD ["/opt/start.sh"]
