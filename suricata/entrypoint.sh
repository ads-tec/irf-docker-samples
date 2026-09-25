#!/bin/bash
# Suricata IDS demo container for the Docker Monitor Port of ADS-TEC IRF3000.
#
# The IRF moves the Monitor Port (e.g. ETH2) into containers started with
# --label monitor=yes. Suricata captures on that interface and writes its
# alerts to /var/log/suricata/eve.json, which EveBox can read from the shared
# volume. Arguments are passed to suricata; without arguments it captures on
# IDS_INTERFACE.
set -euo pipefail

IDS_INTERFACE="${IDS_INTERFACE:-ETH2}"
HOME_NET="${HOME_NET:-}"                    # e.g. [192.168.0.0/24]; empty: keep suricata.yaml
RULE_UPDATE="${RULE_UPDATE:-yes}"           # suricata-update at start and daily
RULE_UPDATE_HOUR="${RULE_UPDATE_HOUR:-2}"
export RULE_URL="${RULE_URL:-}"             # rule source instead of ET Open (e.g. internal mirror)
LOG_MAX_SIZE="${LOG_MAX_SIZE:-200M}"        # per log file, one rotated generation (.1)
SSH="${SSH:-yes}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_AUTHORIZED_KEYS="${SSH_AUTHORIZED_KEYS:-}"

LOG_DIR=/var/log/suricata
STATE_DIR=/var/lib/suricata
SSH_DIR="${STATE_DIR}/.sshd"
CONF=/etc/suricata/suricata.yaml

mkdir -p "${LOG_DIR}" "${STATE_DIR}/rules" /var/run/suricata
chmod 0755 "${LOG_DIR}"

# --- suricata.yaml -----------------------------------------------------------
cp "${CONF}.in" "${CONF}"
# capture interface of the af-packet section (first entry)
sed -i "0,/^  - interface: ETH2$/s//  - interface: ${IDS_INTERFACE}/" "${CONF}"
if [[ -n "${HOME_NET}" ]]; then
    sed -i "s|^    HOME_NET: .*|    HOME_NET: \"${HOME_NET}\"|" "${CONF}"
fi

# --- rules -------------------------------------------------------------------
if [[ "${RULE_UPDATE}" == "yes" ]]; then
    echo "=== Updating rules (suricata-update) ==="
    update-rules.sh || true
fi
[[ -f "${STATE_DIR}/rules/suricata.rules" ]] || : > "${STATE_DIR}/rules/suricata.rules"

# --- SSH ---------------------------------------------------------------------
ssh_info="disabled"
if [[ "${SSH}" == "yes" ]]; then
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
    for t in ed25519 rsa; do
        [[ -f "${SSH_DIR}/ssh_host_${t}_key" ]] || ssh-keygen -q -t "${t}" -N "" -f "${SSH_DIR}/ssh_host_${t}_key"
    done
    password_auth=yes
    if [[ -n "${SSH_AUTHORIZED_KEYS}" ]]; then
        printf '%s\n' "${SSH_AUTHORIZED_KEYS}" > /etc/ssh/authorized_keys/adstec
        chmod 644 /etc/ssh/authorized_keys/adstec
        [[ -z "${SSH_PASSWORD}" ]] && password_auth=no
    fi
    if [[ "${password_auth}" == "yes" && -z "${SSH_PASSWORD}" ]]; then
        # Generated once and kept in the volume, so it survives restarts
        if [[ ! -s "${SSH_DIR}/password" ]]; then
            head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20 > "${SSH_DIR}/password"
            chmod 600 "${SSH_DIR}/password"
            echo "=================================================================="
            echo "  Generated SSH password for user adstec: $(cat "${SSH_DIR}/password")"
            echo "  Stored in ${SSH_DIR}/password"
            echo "=================================================================="
        fi
        SSH_PASSWORD="$(cat "${SSH_DIR}/password")"
    fi
    if [[ "${password_auth}" == "yes" ]]; then
        printf 'adstec:%s\n' "${SSH_PASSWORD}" | chpasswd >/dev/null 2>&1
    else
        sed -i 's|^adstec:[^:]*:|adstec:*:|' /etc/shadow
    fi
    unset SSH_PASSWORD
    cat > /etc/ssh/sshd_config <<SSHD
Port 22
HostKey ${SSH_DIR}/ssh_host_ed25519_key
HostKey ${SSH_DIR}/ssh_host_rsa_key
PidFile /run/sshd.pid
PermitRootLogin no
AllowUsers adstec
PubkeyAuthentication yes
AuthorizedKeysFile /etc/ssh/authorized_keys/%u
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 6
LoginGraceTime 30
AllowTcpForwarding no
AllowStreamLocalForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
Subsystem sftp internal-sftp
SSHD
    /usr/sbin/sshd -t
    /usr/sbin/sshd -D -e &
    ssh_info="user adstec on port 22"
    if [[ "${password_auth}" == "yes" ]]; then ssh_info+=", password"; else ssh_info+=", key only"; fi
fi

# --- daily rule update (reloads the rules in the running Suricata) -----------
if [[ "${RULE_UPDATE}" == "yes" ]]; then
    # busybox crond does not pass the environment: RULE_URL and proxies inline
    cron_env="RULE_URL='${RULE_URL}' HTTP_PROXY='${HTTP_PROXY:-}' HTTPS_PROXY='${HTTPS_PROXY:-}' http_proxy='${http_proxy:-}' https_proxy='${https_proxy:-}'"
    echo "0 ${RULE_UPDATE_HOUR} * * * (${cron_env} /usr/local/bin/update-rules.sh && kill -USR2 \$(pidof suricata)) >> ${LOG_DIR}/suricata-update.log 2>&1" > /etc/crontabs/root
    crond -b -l 8
fi

# --- log rotation: one generation per file, reopened via SIGHUP --------------
max_bytes="$(numfmt --from=iec "${LOG_MAX_SIZE}")"
(
    while sleep 60; do
        rotated=0
        for f in "${LOG_DIR}"/*.json "${LOG_DIR}"/*.log; do
            [[ -f "${f}" ]] || continue
            if (( $(stat -c %s "${f}") > max_bytes )); then
                mv -f "${f}" "${f}.1"
                rotated=1
            fi
        done
        (( rotated )) && kill -HUP "$(pidof suricata)" 2>/dev/null || true
    done
) &

if [[ $# -gt 0 ]]; then
    args=("$@")
else
    args=(-i "${IDS_INTERFACE}")
fi

echo "=== Suricata IDS starting ==="
echo "  Suricata:  $(suricata -V | sed 's/This is Suricata version //')"
echo "  Arguments: ${args[*]}"
echo "  HOME_NET:  $(sed -n 's/^    HOME_NET: //p' "${CONF}")"
rule_count="$(grep -c -E '^alert|^drop|^pass|^reject' "${STATE_DIR}/rules/suricata.rules" || true)"
if grep -q -m1 'msg:"ET ' "${STATE_DIR}/rules/suricata.rules"; then rule_set="Emerging Threats Open + Suricata"; else rule_set="Suricata built-in only (no ET Open download yet)"; fi
echo "  Rules:     ${rule_count} active (${rule_set}), daily update: ${RULE_UPDATE}"
echo "  Logs:      ${LOG_DIR} (eve.json for EveBox), max. ${LOG_MAX_SIZE} per file"
echo "  SSH:       ${ssh_info}"

exec suricata -c "${CONF}" "${args[@]}"
