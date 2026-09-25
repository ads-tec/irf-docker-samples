#!/bin/bash
# Update the Suricata rules with suricata-update.
#
# suricata-update exits 0 even if the download fails and then writes only the
# built-in rules, which would replace a working rule set. So the new rules are
# written to a temporary directory and only taken over if the download
# worked. Without any rules yet (first start without internet access) the
# built-in rules are used.
#
# RULE_URL: rule source instead of Emerging Threats Open, e.g. an internal
# mirror (http://mirror/emerging.rules.tar.gz) for IRFs without internet.
set -uo pipefail

RULES_DIR=/var/lib/suricata/rules
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

args=(--no-test -o "${tmp}")
[[ -n "${RULE_URL:-}" ]] && args+=(--url "${RULE_URL}")

log="$(suricata-update "${args[@]}" 2>&1)"
rc=$?
if (( rc != 0 )) || grep -q -E "Failed to fetch|<Error>" <<< "${log}"; then
    echo "WARNING: rule download failed - keeping the current rules." >&2
    echo "  No internet access from the container? Set HTTP_PROXY/HTTPS_PROXY, or RULE_URL for a local mirror." >&2
    grep -E "Failed to fetch|<Error>" <<< "${log}" | head -3 >&2
    if [[ ! -s "${RULES_DIR}/suricata.rules" && -s "${tmp}/suricata.rules" ]]; then
        cp "${tmp}"/* "${RULES_DIR}/"
        echo "  No rules yet: using the Suricata built-in rules." >&2
    fi
    exit 1
fi
cp "${tmp}"/* "${RULES_DIR}/"
grep -o "total: [0-9]*; enabled: [0-9]*" <<< "${log}" | tail -1 | sed 's/^/Rules updated: /'
exit 0
