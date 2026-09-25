FROM alpine:3.22

# HTTP_PROXY / HTTPS_PROXY are predefined build args in Docker; pass them with
# --build-arg only when building behind an HTTP proxy. They are NOT baked
# into the final image, so the published image stays portable.

# Some build networks intercept HTTPS (TLS-inspecting proxies). apk verifies
# package signatures, so the build fetches over HTTP and restores the HTTPS
# repositories afterwards.
RUN sed -i 's|^https://|http://|' /etc/apk/repositories && \
    apk add --no-cache \
        bash \
        coreutils \
        findutils \
        gzip \
        less \
        lnav \
        openssh-server \
        openssl \
        ripgrep \
        syslog-ng \
        syslog-ng-json \
        syslog-ng-scl \
        syslog-ng-tags-parser \
        tini \
        tzdata && \
    sed -i 's|^http://|https://|' /etc/apk/repositories

# Log viewing over SSH: user "logs" reads the log volume via group "logview"
RUN addgroup -g 1500 logview && \
    adduser -D -u 1000 -h /home/logs -s /bin/bash -G logview logs && \
    mkdir -p /etc/ssh/authorized_keys && \
    rm -f /etc/ssh/ssh_host_*

COPY motd /etc/motd
COPY syslog-ng.conf /etc/syslog-ng/syslog-ng.conf.in
COPY entrypoint.sh /entrypoint.sh
COPY log-retention.sh /usr/local/bin/log-retention.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/log-retention.sh

VOLUME ["/var/log/remote"]

EXPOSE 514/udp 514/tcp 601/tcp 6514/tcp 2222/tcp

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
