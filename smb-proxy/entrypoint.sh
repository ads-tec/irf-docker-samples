#!/bin/bash
set -euo pipefail

SMB_HOST="${SMB_HOST:-192.168.0.250}"
SMB_SHARE="${SMB_SHARE:-SharedFolder}"
SMB_USER="${SMB_USER:-xpuser}"
SMB_PASS="${SMB_PASS:-xppass123}"
SMB_WORKGROUP="${SMB_WORKGROUP:-WORKGROUP}"
LOCAL_USER="${LOCAL_USER:-smbuser}"
LOCAL_PASSWORD="${LOCAL_PASSWORD:-smbpass123}"
MOUNT_ROOT="${MOUNT_ROOT:-/mnt/xp}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-30}"

mkdir -p /root/.smb "${MOUNT_ROOT}" /run/samba /var/lib/samba/private

cat > /root/.smb/smb.conf <<EOF
[global]
  workgroup = ${SMB_WORKGROUP}
  client min protocol = NT1
  client max protocol = NT1
  ntlm auth = ntlmv1-permitted
  lanman auth = yes
EOF

cat > /root/.smb/smbnetfs.conf <<'EOF'
include "smbnetfs.auth"
include "smbnetfs.host"
EOF

cat > /root/.smb/smbnetfs.auth <<EOF
auth "${SMB_HOST}/${SMB_SHARE}" "${SMB_USER}" "${SMB_PASS}"
EOF

cat > /root/.smb/smbnetfs.host <<EOF
host ${SMB_HOST}
EOF

chmod 600 /root/.smb/smbnetfs.auth
chmod 600 /root/.smb/smbnetfs.host

if ! id -u "${LOCAL_USER}" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${LOCAL_USER}"
fi

printf '%s\n%s\n' "${LOCAL_PASSWORD}" "${LOCAL_PASSWORD}" | smbpasswd -a -s "${LOCAL_USER}" >/dev/null

echo "=== Starting smbnetfs FUSE mount ==="
echo "  Source: //${SMB_HOST}/${SMB_SHARE}"
echo "  Mount root: ${MOUNT_ROOT}"

smbnetfs "${MOUNT_ROOT}" -f -o "allow_other,auto_unmount,uid=0,gid=0" &
SMBNETFS_PID=$!

cleanup() {
    local rc=$?
    if [[ -n "${SMBNETFS_PID:-}" ]] && kill -0 "${SMBNETFS_PID}" >/dev/null 2>&1; then
        kill "${SMBNETFS_PID}" >/dev/null 2>&1 || true
        wait "${SMBNETFS_PID}" >/dev/null 2>&1 || true
    fi
    exit "${rc}"
}
trap cleanup EXIT INT TERM

REMOTE_PATH="${MOUNT_ROOT}/${SMB_HOST}/${SMB_SHARE}"
for _ in $(seq 1 "${WAIT_TIMEOUT}"); do
    if [[ -d "${REMOTE_PATH}" ]]; then
        break
    fi
    sleep 1
done

if [[ ! -d "${REMOTE_PATH}" ]]; then
    echo "ERROR: smbnetfs did not expose ${REMOTE_PATH} within ${WAIT_TIMEOUT}s" >&2
    exit 1
fi

sed "s|@@EXPORT_PATH@@|${REMOTE_PATH}|g" /etc/samba/smb.conf > /etc/samba/smb.conf.runtime
mv /etc/samba/smb.conf.runtime /etc/samba/smb.conf

testparm -s /etc/samba/smb.conf >/dev/null

echo "=== Samba CIFS proxy starting ==="
echo "  FUSE path: ${REMOTE_PATH}"
echo "  Re-export: smb://<this-host>/xp-share (SMB2/3, live share)"

exec smbd --foreground --no-process-group --configfile=/etc/samba/smb.conf
