# Suricata IDS demo container for the Docker Monitor Port of ADS-TEC IRF3000
FROM alpine:3.22

# HTTP_PROXY / HTTPS_PROXY are predefined build args in Docker; pass them with
# --build-arg only when building behind an HTTP proxy. They are NOT baked
# into the final image.

# Some build networks intercept HTTPS (TLS-inspecting proxies). apk verifies
# package signatures, so the build fetches over HTTP and restores the HTTPS
# repositories afterwards.
RUN sed -i 's|^https://|http://|' /etc/apk/repositories && \
    apk add --no-cache \
        bash \
        coreutils \
        htop \
        openssh-server \
        suricata \
        tcpdump \
        tini && \
    sed -i 's|^http://|https://|' /etc/apk/repositories

# SSH user for looking at the IDS (htop, tcpdump, logs); password is set at
# start. No root password, no setuid su.
RUN adduser -D -u 1000 -h /home/adstec -s /bin/bash adstec && \
    mkdir -p /etc/ssh/authorized_keys && \
    rm -f /etc/ssh/ssh_host_*

# suricata.yaml from Suricata 7.0.7, adapted to the IRF (capture interface
# ETH2 = Docker Monitor Port); rendered at start (HOME_NET, interface)
COPY suricata.yaml /etc/suricata/suricata.yaml.in
COPY entrypoint.sh /entrypoint.sh
COPY update-rules.sh /usr/local/bin/update-rules.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/update-rules.sh

# eve.json etc. (shared with EveBox) / rules, SSH host keys, password
VOLUME ["/var/log/suricata", "/var/lib/suricata"]

EXPOSE 22

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
