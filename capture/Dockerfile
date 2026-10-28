# syntax=docker/dockerfile:1.7
#
# HTTP_PROXY / HTTPS_PROXY are predefined build args in Docker; pass them with
# --build-arg only when building behind an HTTP proxy. They are NOT baked
# into the final image, so the published image stays portable.
#
# Behind a TLS-inspecting proxy, the downloads outside apk (libpcap source,
# webshark git, npm) need the proxy's CA: pass it as an optional build
# secret, --secret id=build_ca,src=proxy-ca.pem
# It is only used in the build stages and never ends up in the image.

ARG ALPINE=alpine:3.22

# --- libpcap with remote capture (rpcap) support + rpcapcat ----------------
# Alpine's libpcap is built without --enable-remote. Same version, same
# soname, so it replaces the library that tshark links against.
FROM ${ALPINE} AS pcap
ARG LIBPCAP_VERSION=1.10.7
ARG LIBPCAP_SHA256=68fa62cffb974f4275641ce14c2e2d75739251f30e00e6a0900903b247d76a03
RUN sed -i 's|^https://|http://|' /etc/apk/repositories && \
    apk add --no-cache build-base bison flex linux-headers ca-certificates curl
RUN --mount=type=secret,id=build_ca,required=false \
    if [ -s /run/secrets/build_ca ]; then cat /run/secrets/build_ca >> /etc/ssl/certs/ca-certificates.crt; fi && \
    curl -fsSL -o /tmp/libpcap.tar.xz https://www.tcpdump.org/release/libpcap-${LIBPCAP_VERSION}.tar.xz && \
    echo "${LIBPCAP_SHA256}  /tmp/libpcap.tar.xz" | sha256sum -c - && \
    mkdir -p /src && tar xJf /tmp/libpcap.tar.xz -C /src
WORKDIR /src/libpcap-${LIBPCAP_VERSION}
RUN ./configure --prefix=/usr --enable-remote --enable-ipv6 \
        --disable-dbus --disable-rdma --disable-bluetooth --without-libnl && \
    make -j"$(nproc)" && make install DESTDIR=/out && \
    make -C rpcapd install DESTDIR=/out
COPY src/rpcapcat.c /src/rpcapcat.c
RUN cc -O2 -Wall -Wextra -o /out/usr/bin/rpcapcat /src/rpcapcat.c \
        -I/out/usr/include -L/out/usr/lib -lpcap && \
    strip /out/usr/bin/rpcapcat /out/usr/lib/libpcap.so.*.*.* /out/usr/sbin/rpcapd

# --- webshark-ng UI (platform independent, built once on the build host) ---
# Pinned commit of https://github.com/hepictel/webshark (AGPL-3.0), unmodified.
FROM --platform=$BUILDPLATFORM node:22-bookworm AS ui
ARG WEBSHARK_COMMIT=aa7f827f45d4e309f1ce8219b004691d21b4c029
RUN --mount=type=secret,id=build_ca,required=false \
    if [ -s /run/secrets/build_ca ]; then \
        cat /run/secrets/build_ca >> /etc/ssl/certs/ca-certificates.crt; \
        export NODE_EXTRA_CA_CERTS=/run/secrets/build_ca; \
    fi && \
    git init -q /src && cd /src && \
    git fetch -q --depth 1 https://github.com/hepictel/webshark.git "${WEBSHARK_COMMIT}" && \
    git checkout -q FETCH_HEAD && \
    cd ui && npm ci --no-audit --no-fund && npm run build && \
    mkdir -p /web && cp -a dist/webshark/. /web/ && \
    sed -i 's|href="/"|href="/webshark/"|g' /web/index.html && \
    sh /src/scripts/vendor-offline-fonts.sh /web && \
    # smaller image: no source maps, files over 64 KiB only gzip-compressed
    # (capture-web serves them with Content-Encoding: gzip)
    find /web -name '*.map' -delete && \
    find /web -type f -name '*.gz' | while read -r f; do \
        if zcat "$f" | cmp -s - "${f%.gz}"; then rm -f "${f%.gz}"; else rm -f "$f"; fi; \
    done && \
    find /web -type f ! -name '*.gz' ! -name index.html -size +64k -exec gzip -9 {} + && \
    cp /src/LICENSE /web/LICENSE.txt && \
    printf 'https://github.com/hepictel/webshark/tree/%s\n' "${WEBSHARK_COMMIT}" > /web/SOURCE.txt

# --- capture-web: webshark API replacement (static Go binary) --------------
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS web
ARG TARGETOS TARGETARCH TARGETVARIANT
WORKDIR /src
COPY web/ .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH GOARM=${TARGETVARIANT#v} \
    go build -trimpath -ldflags="-s -w" -o /capture-web .

# --- runtime ----------------------------------------------------------------
FROM ${ALPINE}

# Some build networks intercept HTTPS (TLS-inspecting proxies). apk verifies
# package signatures, so the build fetches over HTTP and restores the HTTPS
# repositories afterwards.
RUN sed -i 's|^https://|http://|' /etc/apk/repositories && \
    apk add --no-cache \
        bash \
        coreutils \
        findutils \
        less \
        openssh-server \
        tini \
        tshark \
        tzdata && \
    apk add --no-cache --virtual .setcap libcap-setcap && \
    # file capabilities on dumpcap make exec fail (EPERM) in a container
    # without CAP_NET_ADMIN; rpcap needs none, dumpcap only reads a pipe
    setcap -r /usr/bin/dumpcap && chmod 0755 /usr/bin/dumpcap && \
    apk del .setcap && \
    sed -i 's|^http://|https://|' /etc/apk/repositories

# libpcap with rpcap support replaces Alpine's (same version and soname)
COPY --from=pcap /out/usr/lib/libpcap.so.1.10.7 /usr/lib/libpcap.so.1.10.7
COPY --from=pcap /out/usr/bin/rpcapcat /usr/bin/rpcapcat
COPY --from=web /capture-web /usr/bin/capture-web
COPY --from=ui /web /usr/share/webshark

# SSH user "cap" records into /captures; the web server runs as "cap" too
# (dumpcap creates its files 0600)
RUN addgroup -g 1500 capture && \
    adduser -D -u 1000 -h /home/cap -s /bin/bash -G capture cap && \
    mkdir -p /etc/ssh/authorized_keys && \
    rm -f /etc/ssh/ssh_host_*

COPY motd /etc/motd
COPY entrypoint.sh /entrypoint.sh
COPY bin/ /usr/local/bin/
RUN chmod +x /entrypoint.sh /usr/local/bin/*

# /captures: recordings (a volume, or a tmpfs: --tmpfs /captures:size=200m)
# /state: SSH host keys and generated passwords
VOLUME ["/captures", "/state"]

EXPOSE 2223/tcp

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
