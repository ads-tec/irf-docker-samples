#!/bin/bash
# Samba AD Domain Controller for rootless Docker on ADS-TEC IRF devices.
#
# Rootless Docker storage on the IRF cannot hold security.* / trusted.* xattrs
# and has no POSIX ACL support (btrfs "noacl"), both of which a Samba DC
# normally needs for sysvol. We therefore store all xattrs (NT ACLs, DOS
# attributes) in a TDB database via vfs_xattr_tdb and never touch POSIX ACLs
# ("acl_xattr:ignore system acls"). Samba flags the TDB xattr store as "not
# for production" - accepted for this use case.
set -euo pipefail

REALM="${REALM:-IRF.LAN}"
DOMAIN="${DOMAIN:-IRF}"
DC_HOSTNAME="${DC_HOSTNAME:-DC1}"
# Administrator password, only used at provisioning. If unset, a random one
# is generated and printed once to the container log.
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
# IP that clients use to reach the DC (the IRF uplink address). It is what
# gets registered in DNS instead of the rootless namespace address.
HOST_IP="${HOST_IP:-192.168.0.254}"
DNS_FORWARDER="${DNS_FORWARDER:-}"
RPC_PORT_RANGE="${RPC_PORT_RANGE:-49152-49172}"
DOMAIN_FUNCTION_LEVEL="${DOMAIN_FUNCTION_LEVEL:-2008_R2}"
LOG_LEVEL="${LOG_LEVEL:-1}"

REALM="${REALM^^}"
DOMAIN="${DOMAIN^^}"
realm_lc="${REALM,,}"

PRIVATE_DIR=/var/lib/samba/private
XATTR_TDB="${PRIVATE_DIR}/xattr.tdb"
# xattr_tdb keys its entries by file_id (st_dev + inode). On the IRF st_dev of
# the btrfs subvolume is a dynamically allocated anonymous device number that
# may change between boots, which would orphan every stored ACL. vfs_fileid
# with "fsname" derives the device part from the block device name instead.
VFS_OBJECTS="dfs_samba4 acl_xattr xattr_tdb fileid"
FILEID_ALGORITHM="fsname"
XATTR_KEYING="fileid:${FILEID_ALGORITHM}"
KEYING_MARKER="${PRIVATE_DIR}/xattr_tdb.keying"
SYSVOL_RESET="${SYSVOL_RESET:-0}"
SMB_CONF=/etc/samba/smb.conf

# Default the DNS forwarder to whatever Docker gave us (the IRF's dnsmasq,
# 10.0.3.1), then let the container resolve through the DC's own DNS so
# Kerberos/LDAP SRV lookups for the realm work locally.
if [[ -z "${DNS_FORWARDER}" ]]; then
    DNS_FORWARDER="$(awk '$1 == "nameserver" && $2 !~ /^127\./ {print $2; exit}' /etc/resolv.conf || true)"
fi

mkdir -p /var/lib/samba /var/log/samba /run/samba "${PRIVATE_DIR}" /etc/samba

if [[ ! -f "${PRIVATE_DIR}/sam.ldb" ]]; then
    echo "=== Provisioning new domain ${REALM} (${DOMAIN}) ==="
    generated_password=0
    if [[ -z "${ADMIN_PASSWORD}" ]]; then
        # Upper + lower + digit + symbol to satisfy the AD complexity policy
        ADMIN_PASSWORD="$(python3 -c 'import secrets, string
a = string.ascii_letters + string.digits
print("".join(secrets.choice(a) for _ in range(16)) + "Aa1-")')"
        generated_password=1
    fi
    rm -f "${SMB_CONF}"

    provision_opts=(
        --server-role=dc
        --use-rfc2307
        --dns-backend=SAMBA_INTERNAL
        --realm="${REALM}"
        --domain="${DOMAIN}"
        --host-name="${DC_HOSTNAME}"
        --host-ip="${HOST_IP}"
        --adminpass="${ADMIN_PASSWORD}"
        --function-level="${DOMAIN_FUNCTION_LEVEL}"
        --option="vfs objects = ${VFS_OBJECTS}"
        --option="xattr_tdb:file = ${XATTR_TDB}"
        --option="fileid:algorithm = ${FILEID_ALGORITHM}"
        --option="acl_xattr:ignore system acls = yes"
    )
    samba-tool domain provision "${provision_opts[@]}"
    echo "${XATTR_KEYING}" > "${KEYING_MARKER}"
    if [[ "${generated_password}" == "1" ]]; then
        echo "=================================================================="
        echo "  Generated Administrator password: ${ADMIN_PASSWORD}"
        echo "  Change it: samba-tool user setpassword Administrator"
        echo "=================================================================="
    fi
else
    echo "=== Existing domain found, skipping provisioning ==="
fi

# Render smb.conf on every start so env changes (forwarder, RPC range, log
# level) apply to an existing domain as well.
write_smb_conf() {
    cat > "${SMB_CONF}" <<EOF
[global]
   netbios name = ${DC_HOSTNAME}
   realm = ${REALM}
   workgroup = ${DOMAIN}
   server role = active directory domain controller
   idmap_ldb:use rfc2307 = yes
   vfs objects = ${VFS_OBJECTS}
   xattr_tdb:file = ${XATTR_TDB}
   fileid:algorithm = ${FILEID_ALGORITHM}
   acl_xattr:ignore system acls = yes
   rpc server dynamic port range = ${RPC_PORT_RANGE}
   # samba_dnsupdate would register the rootless namespace IP (10.0.3.x),
   # which clients cannot reach. DNS keeps the provisioned HOST_IP records.
   dns update command = /bin/true
   ${DNS_FORWARDER:+dns forwarder = ${DNS_FORWARDER}}
   usershare path =
   log level = ${LOG_LEVEL}
   max log size = 1000

[sysvol]
   path = /var/lib/samba/sysvol
   read only = no

[netlogon]
   path = /var/lib/samba/sysvol/${realm_lc}/scripts
   read only = no
EOF
}
write_smb_conf

# Container-local krb5.conf: DNS publishes HOST_IP (the IRF), which is not
# reachable from inside the rootless namespace, so point local tools (kinit,
# smbclient -k, samba-tool -k) at loopback. Clients use private/krb5.conf.
cat > /etc/krb5.conf <<EOF
[libdefaults]
	default_realm = ${REALM}
	dns_lookup_realm = false
	dns_lookup_kdc = false

[realms]
${REALM} = {
	kdc = 127.0.0.1
	admin_server = 127.0.0.1
	default_domain = ${realm_lc}
}

[domain_realm]
	.${realm_lc} = ${REALM}
	${realm_lc} = ${REALM}
EOF
printf 'search %s\nnameserver 127.0.0.1\n' "${realm_lc}" > /etc/resolv.conf
dc_fqdn="${DC_HOSTNAME,,}.${realm_lc}"
grep -q " ${dc_fqdn}" /etc/hosts || echo "127.0.0.1 ${dc_fqdn} ${DC_HOSTNAME,,}" >> /etc/hosts

testparm -s "${SMB_CONF}" >/dev/null

# Stored sysvol ACLs are unreachable when the xattr_tdb keying changed (older
# image) or the files got new inodes (restore from tar/rsync). Sysvol ACLs
# are derived from AD, so re-apply them. SYSVOL_RESET=1 forces this, e.g.
# after a restore.
if [[ "$(cat "${KEYING_MARKER}" 2>/dev/null)" != "${XATTR_KEYING}" || "${SYSVOL_RESET}" == "1" ]]; then
    echo "=== Re-applying sysvol ACLs (samba-tool ntacl sysvolreset) ==="
    # Entries under the old keys are orphans that could match a reused inode
    # later - start from an empty store, keep the old one for reference.
    if [[ -f "${XATTR_TDB}" ]]; then
        mv "${XATTR_TDB}" "${XATTR_TDB}.$(date +%Y%m%d%H%M%S).old"
    fi
    samba-tool ntacl sysvolreset
    echo "${XATTR_KEYING}" > "${KEYING_MARKER}"
fi

echo "=== Samba AD DC starting ==="
echo "  Realm:   ${REALM}"
echo "  Domain:  ${DOMAIN}"
echo "  DC:      ${DC_HOSTNAME}.${realm_lc} (${HOST_IP})"
echo "  xattrs:  ${XATTR_TDB} (vfs_xattr_tdb, keyed by ${XATTR_KEYING})"
echo "  RPC:     ${RPC_PORT_RANGE}"
echo "  DNS fwd: ${DNS_FORWARDER:-none}"

exec samba --foreground --no-process-group --debug-stdout
