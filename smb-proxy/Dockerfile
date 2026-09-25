FROM debian:bookworm-slim

# HTTP_PROXY / HTTPS_PROXY are predefined build args in Docker; pass them with
# --build-arg only when building behind an HTTP proxy. They are NOT baked
# into the final image, so the published image stays portable.

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        fuse \
        procps \
        samba \
        smbclient \
        smbnetfs \
        tini && \
    rm -rf /var/lib/apt/lists/*

COPY smb.conf /etc/samba/smb.conf
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && \
    mkdir -p /mnt/xp /srv/xp-share /run/samba /var/lib/samba/private /root/.smb && \
    printf 'user_allow_other\n' > /etc/fuse.conf

EXPOSE 445 139

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
