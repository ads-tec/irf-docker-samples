FROM debian:trixie-slim

# HTTP_PROXY / HTTPS_PROXY are predefined build args in Docker; pass them with
# --build-arg only when building behind an HTTP proxy. They are NOT baked
# into the final image, so the published image stays portable.

ENV DEBIAN_FRONTEND=noninteractive
# See the provision patch below; also needed by "samba-tool ntacl sysvolreset".
ENV SAMBA_NO_POSIX_ACLS=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        acl \
        attr \
        bind9-dnsutils \
        iproute2 \
        krb5-user \
        ldb-tools \
        procps \
        samba \
        samba-ad-dc \
        samba-ad-provision \
        samba-dsdb-modules \
        samba-vfs-modules \
        smbclient \
        tdb-tools \
        tini \
        winbind && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/samba/smb.conf /etc/krb5.conf

# Rootless Docker on the IRF: the volume is btrfs mounted "noacl", security.*
# and trusted.* xattrs are denied, and only UIDs/GIDs 0-65536 are mapped.
#
# 1. The provision precheck insists on POSIX ACL support. We run with
#    "acl_xattr:ignore system acls = yes" + vfs_xattr_tdb (NT ACLs in a TDB,
#    no POSIX ACLs at all), so skip that check when SAMBA_NO_POSIX_ACLS=1.
# 2. Move the idmap allocation range (default 3000000-4000000) into the
#    mapped UID range, otherwise chown and user impersonation fail (EINVAL).
RUN f=/usr/lib/python3/dist-packages/samba/provision/__init__.py && \
    sed -i 's|^\( *\)smbd.set_simple_acl(file.name, 0o755, system_session_unix(), gid)$|\1if os.environ.get("SAMBA_NO_POSIX_ACLS") != "1": smbd.set_simple_acl(file.name, 0o755, system_session_unix(), gid)|' "$f" && \
    grep -q 'SAMBA_NO_POSIX_ACLS' "$f" && \
    rm -rf /usr/lib/python3/dist-packages/samba/provision/__pycache__ && \
    sed -i -e 's/^lowerBound: .*/lowerBound: 10000/' -e 's/^upperBound: .*/upperBound: 60000/' \
        /usr/share/samba/setup/idmap_init.ldif && \
    grep -q '^lowerBound: 10000' /usr/share/samba/setup/idmap_init.ldif

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/var/lib/samba"]

EXPOSE 53/tcp 53/udp 88/tcp 88/udp 135/tcp 137/udp 138/udp 139/tcp \
       389/tcp 389/udp 445/tcp 464/tcp 464/udp 636/tcp 3268/tcp 3269/tcp \
       49152-49172/tcp

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
