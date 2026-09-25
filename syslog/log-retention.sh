#!/bin/bash
# Enforce retention and the total size cap of the log volume.
#   1. gzip finished hour files (not the current hour, idle for 2 minutes)
#   2. delete files older than LOG_RETENTION_DAYS
#   3. delete the oldest files until the total is below LOG_MAX_SIZE; the
#      current hour's files are only truncated if nothing older is left
#   4. remove empty sender directories
# Hidden directories (.tls, .sshd) hold state, not logs, and are skipped.
set -euo pipefail

LOG_DIR="${LOG_DIR:-/var/log/remote}"
LOG_MAX_SIZE="${LOG_MAX_SIZE:-1G}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-90}"

max_bytes="$(numfmt --from=iec "${LOG_MAX_SIZE}")"
current="$(date +%Y-%m-%d_%H).log"

# 1. compress finished hour files
find "${LOG_DIR}" -type f -name '*.log' ! -name "${current}" -mmin +2 ! -path "${LOG_DIR}/.*" -print0 |
    while IFS= read -r -d '' f; do gzip -9 -f "${f}"; done

# 2. retention by age
find "${LOG_DIR}" -type f -name '*.log*' -mtime +"${LOG_RETENTION_DAYS}" ! -path "${LOG_DIR}/.*" -print -delete |
    sed 's/^/retention: removed (age) /'

# 3. size cap: oldest files first, the current hour's files last.
#    Sender directory names are sanitized by syslog-ng, no newlines in paths.
total="$(du -sb --exclude="${LOG_DIR}/.*" "${LOG_DIR}" | cut -f1)"
if (( total > max_bytes )); then
    all="$(find "${LOG_DIR}" -type f -name '*.log*' ! -path "${LOG_DIR}/.*" -printf '%T@ %p\n' | sort -n | cut -d' ' -f2-)"
    candidates="$(grep -v -F "/${current}" <<< "${all}" || true)
$(grep -F "/${current}" <<< "${all}" || true)"
    while IFS= read -r f; do
        (( total > max_bytes )) || break
        [[ -n "${f}" && -f "${f}" ]] || continue
        size="$(stat -c %s "${f}")"
        if [[ "$(basename "${f}")" == "${current}" ]]; then
            # syslog-ng appends, so a truncated active file keeps working
            : > "${f}"
            echo "retention: truncated (size cap) ${f}"
        else
            rm -f "${f}"
            echo "retention: removed (size cap) ${f}"
        fi
        total=$(( total - size ))
    done <<< "${candidates}"
fi

# 4. empty sender directories
find "${LOG_DIR}" -mindepth 1 -type d -empty ! -path "${LOG_DIR}/.*" -delete
