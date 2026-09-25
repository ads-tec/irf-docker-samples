# mbusd - Modbus TCP to Modbus RTU gateway (https://github.com/3cky/mbusd)
#
# The upstream source tarball is kept in src/ and verified here against a
# pinned SHA-256.
FROM alpine:3.22 AS build

ARG MBUSD_VERSION=0.5.3
ARG MBUSD_SHA256=9bca31bb86aa4db50826ee53e967e6736abd42554941aab7fb389938287454bb

# Some build networks intercept HTTPS (TLS-inspecting proxies). apk verifies
# package signatures, so the build fetches over HTTP.
RUN sed -i 's|^https://|http://|' /etc/apk/repositories && \
    apk add --no-cache build-base cmake linux-headers pkgconf

COPY src/mbusd-${MBUSD_VERSION}.tar.gz /tmp/
RUN echo "${MBUSD_SHA256}  /tmp/mbusd-${MBUSD_VERSION}.tar.gz" | sha256sum -c - && \
    tar xzf /tmp/mbusd-${MBUSD_VERSION}.tar.gz -C /tmp && \
    cmake -S /tmp/mbusd-${MBUSD_VERSION} -B /tmp/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr && \
    cmake --build /tmp/build -j"$(nproc)" && \
    cmake --install /tmp/build --strip && \
    install -D -m 644 /tmp/mbusd-${MBUSD_VERSION}/LICENSE /usr/share/licenses/mbusd/LICENSE

FROM alpine:3.22

# HTTP_PROXY / HTTPS_PROXY are predefined build args in Docker; pass them with
# --build-arg only when building behind an HTTP proxy. They are NOT baked
# into the final image.
RUN sed -i 's|^https://|http://|' /etc/apk/repositories && \
    apk add --no-cache bash tini && \
    sed -i 's|^http://|https://|' /etc/apk/repositories

COPY --from=build /usr/bin/mbusd /usr/bin/mbusd
COPY --from=build /usr/share/licenses/mbusd/LICENSE /usr/share/licenses/mbusd/LICENSE
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 502/tcp

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
