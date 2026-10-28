#!/bin/bash
# Packet capture for rootless Docker on ADS-TEC IRF devices.
#
# The IRF's own rpcapd does the capturing; this container connects to it over
# the Docker interface (rpcapcat), so it needs no privileges. tshark over SSH
# (user "cap"), recordings in /captures, webshark-ng web UI on 127.0.0.1:8085
# (reached through an SSH tunnel).
set -euo pipefail

CAPTURES_PATH=/captures
CAPTURE_MAX_SIZE="${CAPTURE_MAX_SIZE:-1G}"
CAPTURE_RETENTION_DAYS="${CAPTURE_RETENTION_DAYS:-14}"
# Free space kept on the Docker partition (shared with images and other
# containers): a percentage of the partition or a size (2G)
CAPTURE_MIN_FREE="${CAPTURE_MIN_FREE:-15%}"
RETENTION_INTERVAL="${RETENTION_INTERVAL:-30}"
RECORD_FILE_SIZE="${RECORD_FILE_SIZE:-50M}"
# rpcapd of the IRF: default gateway of the Docker namespace (the IRF's
# Docker interface address)
RPCAP_HOST="${RPCAP_HOST:-$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')}"
RPCAP_PORT="${RPCAP_PORT:-2002}"
# Optional recording started with the container: interface and filter
RECORD_IFACE="${RECORD_IFACE:-}"
RECORD_FILTER="${RECORD_FILTER:-}"
SSH_PORT="${SSH_PORT:-2223}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_AUTHORIZED_KEYS="${SSH_AUTHORIZED_KEYS:-}"
# SSH host keys and generated passwords: persistent, separate from the
# captures (which may be a tmpfs)
STATE_DIR="${STATE_DIR:-/state}"
SSH_DIR="${STATE_DIR}/.sshd"
WEB="${WEB:-yes}"
WEB_LISTEN="${WEB_LISTEN:-127.0.0.1:8085}"
WEB_PASSWORD="${WEB_PASSWORD:-}"
# HTTPS (nginx) in front of the web UI when it is reachable from outside;
# capture-web then listens on WEB_INTERNAL
WEB_TLS="${WEB_TLS:-yes}"
WEB_INTERNAL="${WEB_INTERNAL:-127.0.0.1:8086}"
TLS_CN="${TLS_CN:-irf-capture}"
TLS_SAN="${TLS_SAN:-}"
TZ="${TZ:-UTC}"
export TZ CAPTURES_PATH CAPTURE_MAX_SIZE CAPTURE_RETENTION_DAYS RPCAP_HOST RPCAP_PORT RECORD_FILE_SIZE

mkdir -p "${CAPTURES_PATH}"
CAPTURE_MAX_SIZE_BYTES="$(numfmt --from=iec "${CAPTURE_MAX_SIZE}")"
if [[ "${CAPTURE_MIN_FREE}" == *% ]]; then
    total_bytes=$(( $(stat -f -c '%b * %S' "${CAPTURES_PATH}") ))
    CAPTURE_MIN_FREE_BYTES=$(( total_bytes * ${CAPTURE_MIN_FREE%\%} / 100 ))
else
    CAPTURE_MIN_FREE_BYTES="$(numfmt --from=iec "${CAPTURE_MIN_FREE}")"
fi
export CAPTURE_MAX_SIZE_BYTES CAPTURE_MIN_FREE_BYTES

if [[ -z "${RPCAP_HOST}" ]]; then
    echo "ERROR: no default route, set RPCAP_HOST to the IRF's Docker interface address" >&2
    exit 1
fi

# Captures: written by cap (recordings, uploads), group capture
mkdir -p "${CAPTURES_PATH}" /run/capture
chown root:capture "${CAPTURES_PATH}"
chmod 2770 "${CAPTURES_PATH}"
chown cap:capture /run/capture
find "${CAPTURES_PATH}" -mindepth 1 -maxdepth 1 -type f ! -name '.*' -exec chown cap:capture {} + -exec chmod 0640 {} +

# Settings for SSH sessions and the helper scripts (ssh does not pass the
# container environment on)
cat > /etc/capture.env <<ENV
RPCAP_HOST=${RPCAP_HOST}
RPCAP_PORT=${RPCAP_PORT}
CAPTURES_PATH=${CAPTURES_PATH}
RECORD_FILE_SIZE=${RECORD_FILE_SIZE}
SSH_PORT=${SSH_PORT}
TZ=${TZ}
ENV
chmod 644 /etc/capture.env

# --- SSH (user cap) ---------------------------------------------------------
mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"
# images up to 2026-10-28 kept the state in the captures volume
if [[ ! -d "${SSH_DIR}" && -d "${CAPTURES_PATH}/.sshd" ]]; then
    cp -a "${CAPTURES_PATH}/.sshd" "${SSH_DIR}"
    echo "=== moved SSH host keys and passwords to ${SSH_DIR} ==="
fi
rm -rf "${CAPTURES_PATH}/.sshd"
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
# Persistent host keys: the fingerprint survives container updates
for t in ed25519 rsa; do
    [[ -f "${SSH_DIR}/ssh_host_${t}_key" ]] || ssh-keygen -q -t "${t}" -N "" -f "${SSH_DIR}/ssh_host_${t}_key"
done

password_auth=yes
if [[ -n "${SSH_AUTHORIZED_KEYS}" ]]; then
    printf '%s\n' "${SSH_AUTHORIZED_KEYS}" > /etc/ssh/authorized_keys/cap
    chmod 644 /etc/ssh/authorized_keys/cap
    [[ -z "${SSH_PASSWORD}" ]] && password_auth=no
fi
if [[ "${password_auth}" == "yes" && -z "${SSH_PASSWORD}" ]]; then
    # Generated once and kept in the volume, so it survives restarts
    if [[ ! -s "${SSH_DIR}/password" ]]; then
        head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20 > "${SSH_DIR}/password"
        chmod 600 "${SSH_DIR}/password"
        echo "=================================================================="
        echo "  Generated password for user cap: $(cat "${SSH_DIR}/password")"
        echo "  Stored in ${SSH_DIR}/password"
        echo "=================================================================="
    fi
    SSH_PASSWORD="$(cat "${SSH_DIR}/password")"
fi
if [[ "${password_auth}" == "yes" ]]; then
    printf 'cap:%s\n' "${SSH_PASSWORD}" | chpasswd >/dev/null 2>&1
else
    # '*' = no valid password, but the account is not locked (key login works)
    sed -i 's|^cap:[^:]*:|cap:*:|' /etc/shadow
fi

# Port forwarding is allowed only to the web UI (ssh -L 8085:127.0.0.1:8085)
forwarding=no
permit_open=none
if [[ "${WEB}" == "yes" ]]; then
    forwarding=local
    permit_open="${WEB_LISTEN/#0.0.0.0:/127.0.0.1:}"
fi

cat > /etc/ssh/sshd_config <<SSHD
Port ${SSH_PORT}
HostKey ${SSH_DIR}/ssh_host_ed25519_key
HostKey ${SSH_DIR}/ssh_host_rsa_key
PidFile /run/sshd.pid
PermitRootLogin no
AllowUsers cap
PubkeyAuthentication yes
AuthorizedKeysFile /etc/ssh/authorized_keys/%u
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 60
AllowTcpForwarding ${forwarding}
PermitOpen ${permit_open}
PermitListen none
AllowStreamLocalForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no
SetEnv RPCAP_HOST=${RPCAP_HOST} RPCAP_PORT=${RPCAP_PORT} TZ=${TZ}
PrintMotd yes
Subsystem sftp internal-sftp -u 0027
SSHD
/usr/sbin/sshd -t
/usr/sbin/sshd -D -e &

# --- web UI -----------------------------------------------------------------
web_info="off"
if [[ "${WEB}" == "yes" ]]; then
    web_host="${WEB_LISTEN%:*}"
    if [[ "${web_host}" != "127.0.0.1" && "${web_host}" != "localhost" && "${web_host}" != "[::1]" ]]; then
        # Reachable from outside the container: HTTP basic auth is mandatory.
        # Password: WEB_PASSWORD, else the SSH password, else generated once
        # and kept in the volume.
        WEB_PASSWORD="${WEB_PASSWORD:-${SSH_PASSWORD}}"
        if [[ -z "${WEB_PASSWORD}" ]]; then
            if [[ ! -s "${SSH_DIR}/web_password" ]]; then
                head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20 > "${SSH_DIR}/web_password"
                chmod 600 "${SSH_DIR}/web_password"
                echo "=================================================================="
                echo "  Generated web UI password for user cap: $(cat "${SSH_DIR}/web_password")"
                echo "  Stored in ${SSH_DIR}/web_password"
                echo "=================================================================="
            fi
            WEB_PASSWORD="$(cat "${SSH_DIR}/web_password")"
        fi
        web_info="http://<irf>:${WEB_LISTEN##*:}/ (live capture, webshark; HTTP basic auth, user cap)"
    else
        WEB_PASSWORD=""
        web_info="${WEB_LISTEN}, through ssh -L 8085:${WEB_LISTEN} -p ${SSH_PORT} cap@<irf>"
    fi

    app_listen="${WEB_LISTEN}"
    if [[ -n "${WEB_PASSWORD}" && "${WEB_TLS}" == "yes" ]]; then
        # nginx terminates TLS on WEB_LISTEN, capture-web moves inside
        app_listen="${WEB_INTERNAL}"
        tls_dir="${STATE_DIR}/tls"
        mkdir -p "${tls_dir}"
        chmod 700 "${tls_dir}"
        if [[ ! -s "${tls_dir}/server.crt" || ! -s "${tls_dir}/server.key" ]]; then
            san="DNS:${TLS_CN},DNS:localhost,IP:127.0.0.1${TLS_SAN:+,${TLS_SAN}}"
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
                -subj "/CN=${TLS_CN}" -addext "subjectAltName=${san}" \
                -keyout "${tls_dir}/server.key" -out "${tls_dir}/server.crt" 2>/dev/null
            chmod 600 "${tls_dir}/server.key"
            echo "=== generated a self-signed TLS certificate (${san}) in ${tls_dir} ==="
        fi
        cat > /etc/nginx/nginx.conf <<NGINX
worker_processes 1;
pid /run/nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 256; }
http {
    access_log off;
    server_tokens off;
    client_max_body_size 2g;
    upstream capture_web { server ${app_listen}; }
    server {
        listen ${WEB_LISTEN} ssl;
        http2 on;
        ssl_certificate     ${tls_dir}/server.crt;
        ssl_certificate_key ${tls_dir}/server.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:tls:1m;
        # plain HTTP on the HTTPS port: redirect
        error_page 497 =301 https://\$host:\$server_port\$request_uri;

        # no HSTS: with a self-signed certificate it would lock users out
        # of the browser's certificate exception
        add_header X-Frame-Options SAMEORIGIN always;

        location / {
            proxy_pass http://capture_web;
            proxy_http_version 1.1;
            proxy_set_header Host \$http_host;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header Connection "";
            # live follow (server-sent events) and growing captures: no
            # buffering, long reads
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_read_timeout 1h;
            proxy_send_timeout 1h;
        }
    }
}
NGINX
        nginx -t -q
        # "io_setup() failed (38: Function not implemented)" at start: no
        # Linux AIO in rootless Docker on the IRF, nginx works without it
        nginx -g 'daemon off;' &
        web_info="https://<irf>:${WEB_LISTEN##*:}/ (live capture, webshark; HTTP basic auth, user cap; TLS cert SHA256 $(openssl x509 -in "${tls_dir}/server.crt" -noout -fingerprint -sha256 | cut -d= -f2))"
    fi

    # busybox su keeps the environment: the password is not on a command line
    public_port="${WEB_LISTEN##*:}"
    WEB_LISTEN="${app_listen}" WEB_PUBLIC_PORT="${public_port}" WEB_PASSWORD="${WEB_PASSWORD}" SSH_PORT="${SSH_PORT}" \
        su -s /bin/sh cap -c 'umask 0027; exec /usr/bin/capture-web' &
fi
unset SSH_PASSWORD WEB_PASSWORD

echo "=== packet capture starting ==="
echo "  rpcapd:    ${RPCAP_HOST}:${RPCAP_PORT} (IRF remote capture)"
if ifaces="$(su -s /bin/sh cap -c 'rpcapcat -l' 2>&1)"; then
    echo "  Interfaces: $(awk '{print $1}' <<< "${ifaces}" | tr '\n' ' ')"
else
    echo "  WARNING: rpcapd not reachable: ${ifaces}"
    echo "           enable remote capture on the IRF (setup_rpcap.py)"
fi
echo "  Captures:  ${CAPTURES_PATH}, cap ${CAPTURE_MAX_SIZE}, ${CAPTURE_RETENTION_DAYS} days, ${RECORD_FILE_SIZE} per file"
storage="Docker partition"
[[ "$(stat -f -c %T "${CAPTURES_PATH}")" == tmpfs ]] && storage="RAM (tmpfs, lost on restart)"
echo "  Storage:   ${storage}, $(df -h --output=avail "${CAPTURES_PATH}" | tail -1 | tr -d ' ') free, reserve ${CAPTURE_MIN_FREE} = $(numfmt --to=iec "${CAPTURE_MIN_FREE_BYTES}") (captures stop below it)"
echo "  SSH:       tcp/${SSH_PORT}, user cap, $([[ ${password_auth} == yes ]] && echo password || echo "key only")$([[ -n ${SSH_AUTHORIZED_KEYS} ]] && echo " + authorized key") (fingerprint $(ssh-keygen -l -f "${SSH_DIR}/ssh_host_ed25519_key.pub" | cut -d' ' -f2))"
echo "  Web UI:    ${web_info}"

if [[ -n "${RECORD_IFACE}" ]]; then
    su -s /bin/bash cap -c "record start $(printf '%q' "${RECORD_IFACE}") $(printf '%q' "${RECORD_FILTER}")" || true
fi

# Enforce the size cap / retention in the background
( while true; do /usr/local/bin/capture-retention || true; sleep "${RETENTION_INTERVAL}"; done ) &

# sshd or the web server gone: exit, Docker restarts the container
wait -n
echo "a service exited, stopping" >&2
exit 1
