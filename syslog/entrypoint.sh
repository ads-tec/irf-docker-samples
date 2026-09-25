#!/bin/bash
# syslog-ng log collector for rootless Docker on ADS-TEC IRF devices.
#
# Read-only log access for user "logs" over SSH (lnav, ripgrep, sftp).
# Receives syslog on UDP/TCP 514 (RFC 3164/5424), TCP 601 (RFC 5424) and TLS 6514
# (RFC 5425) and writes one file per sender and day to /var/log/remote.
#
# Rootless Docker on the IRF cannot size-limit a persistent volume (no loop
# mounts, no XFS project quota, no btrfs qgroups for the rootless user), so
# the size cap is enforced here by log-retention.sh.
set -euo pipefail

LOG_DIR=/var/log/remote
LOG_MAX_SIZE="${LOG_MAX_SIZE:-1G}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-90}"
RETENTION_INTERVAL="${RETENTION_INTERVAL:-60}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-100}"
TLS="${TLS:-yes}"
TLS_DIR="${TLS_DIR:-${LOG_DIR}/.tls}"
TLS_PEER_VERIFY="${TLS_PEER_VERIFY:-optional-untrusted}"
LOG_TO_STDOUT="${LOG_TO_STDOUT:-no}"
# Read-only log access over SSH (lnav, ripgrep, sftp)
SSH="${SSH:-yes}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_AUTHORIZED_KEYS="${SSH_AUTHORIZED_KEYS:-}"
SSH_DIR="${LOG_DIR}/.sshd"
TZ="${TZ:-UTC}"
export TZ LOG_DIR LOG_MAX_SIZE LOG_RETENTION_DAYS

mkdir -p "${LOG_DIR}"
# Logs: root-owned, readable for group logview (SSH user "logs"). Also fixes
# files written by older images.
chown root:logview "${LOG_DIR}"
chmod 0750 "${LOG_DIR}"
find "${LOG_DIR}" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec chown -R root:logview {} + -exec chmod -R u=rwX,g=rX,o= {} +

tls_option=""
if [[ "${TLS}" == "yes" ]]; then
    mkdir -p "${TLS_DIR}"
    chmod 700 "${TLS_DIR}"
    if [[ ! -f "${TLS_DIR}/server.crt" || ! -f "${TLS_DIR}/server.key" ]]; then
        echo "=== Generating self-signed TLS certificate in ${TLS_DIR} ==="
        openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
            -subj "/CN=${TLS_CN:-irf-syslog}" \
            -keyout "${TLS_DIR}/server.key" -out "${TLS_DIR}/server.crt" 2>/dev/null
        chmod 600 "${TLS_DIR}/server.key"
    fi
    ca_opt=""
    [[ -f "${TLS_DIR}/ca.crt" ]] && ca_opt="ca-file(\"${TLS_DIR}/ca.crt\")"
    tls_option="        tls(key-file(\"${TLS_DIR}/server.key\") cert-file(\"${TLS_DIR}/server.crt\")
            ${ca_opt} peer-verify(${TLS_PEER_VERIFY}))"
fi

stdout_dest=""
[[ "${LOG_TO_STDOUT}" == "yes" ]] && stdout_dest="destination(d_stdout);"

conf=/etc/syslog-ng/syslog-ng.conf
render_conf() {
    local tpl
    tpl="$(cat "${conf}.in")"
    tpl="${tpl//@@MAX_CONNECTIONS@@/${MAX_CONNECTIONS}}"
    # 100 messages window per connection (syslog-ng minimum recommendation)
    tpl="${tpl//@@LOG_IW_SIZE@@/$(( MAX_CONNECTIONS * 100 ))}"
    tpl="${tpl//@@TLS_OPTION@@/${tls_option}}"
    tpl="${tpl//@@STDOUT_DEST@@/${stdout_dest}}"
    printf '%s\n' "${tpl}" > "${conf}"
}
render_conf
syslog-ng --syntax-only -f "${conf}"

ssh_info=""
if [[ "${SSH}" == "yes" ]]; then
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
    # Persistent host keys: the fingerprint survives container updates
    for t in ed25519 rsa; do
        [[ -f "${SSH_DIR}/ssh_host_${t}_key" ]] || ssh-keygen -q -t "${t}" -N "" -f "${SSH_DIR}/ssh_host_${t}_key"
    done

    password_auth=yes
    if [[ -n "${SSH_AUTHORIZED_KEYS}" ]]; then
        printf '%s\n' "${SSH_AUTHORIZED_KEYS}" > /etc/ssh/authorized_keys/logs
        chmod 644 /etc/ssh/authorized_keys/logs
        [[ -z "${SSH_PASSWORD}" ]] && password_auth=no
    fi
    if [[ "${password_auth}" == "yes" && -z "${SSH_PASSWORD}" ]]; then
        # Generated once and kept in the volume, so it survives restarts
        if [[ ! -s "${SSH_DIR}/password" ]]; then
            head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20 > "${SSH_DIR}/password"
            chmod 600 "${SSH_DIR}/password"
            echo "=================================================================="
            echo "  Generated SSH password for user logs: $(cat "${SSH_DIR}/password")"
            echo "  Stored in ${SSH_DIR}/password"
            echo "=================================================================="
        fi
        SSH_PASSWORD="$(cat "${SSH_DIR}/password")"
    fi
    if [[ "${password_auth}" == "yes" ]]; then
        printf 'logs:%s\n' "${SSH_PASSWORD}" | chpasswd >/dev/null 2>&1
    else
        # '*' = no valid password, but the account is not locked (key login works)
        sed -i 's|^logs:[^:]*:|logs:*:|' /etc/shadow
    fi
    unset SSH_PASSWORD

    cat > /etc/ssh/sshd_config <<SSHD
Port ${SSH_PORT}
HostKey ${SSH_DIR}/ssh_host_ed25519_key
HostKey ${SSH_DIR}/ssh_host_rsa_key
PidFile /run/sshd.pid
PermitRootLogin no
AllowUsers logs
PubkeyAuthentication yes
AuthorizedKeysFile /etc/ssh/authorized_keys/%u
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
AllowTcpForwarding no
AllowStreamLocalForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no
PrintMotd yes
Subsystem sftp internal-sftp
SSHD
    /usr/sbin/sshd -t
    /usr/sbin/sshd -D -e &
    ssh_info="tcp/${SSH_PORT}, user logs"
    if [[ "${password_auth}" == "yes" ]]; then ssh_info+=", password"; else ssh_info+=", key only"; fi
    if [[ -n "${SSH_AUTHORIZED_KEYS}" ]]; then ssh_info+=" + authorized key"; fi
fi

echo "=== syslog-ng log collector starting ==="
echo "  Listen:    udp/514 tcp/514 (RFC 3164/5424), tcp/601 (RFC 5424)$([[ ${TLS} == yes ]] && echo ", tls/6514 (RFC 5425)")"
echo "  Logs:      ${LOG_DIR}/<host>/<YYYY-MM-DD_HH>.log (gzip after the hour)"
echo "  Size cap:  ${LOG_MAX_SIZE}, retention ${LOG_RETENTION_DAYS} days (checked every ${RETENTION_INTERVAL}s)"
[[ -n "${ssh_info}" ]] && echo "  SSH:       ${ssh_info} (fingerprint $(ssh-keygen -l -f "${SSH_DIR}/ssh_host_ed25519_key.pub" | cut -d' ' -f2))"
[[ "${TLS}" == "yes" ]] && echo "  TLS cert:  ${TLS_DIR}/server.crt ($(openssl x509 -in "${TLS_DIR}/server.crt" -noout -fingerprint -sha256 | cut -d= -f2))"

# Enforce the size cap / retention in the background
( while true; do /usr/local/bin/log-retention.sh || true; sleep "${RETENTION_INTERVAL}"; done ) &

exec syslog-ng -F --no-caps -f "${conf}" -p /run/syslog-ng.pid
