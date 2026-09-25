#!/bin/bash
# Modbus TCP to Modbus RTU gateway (mbusd) for rootless Docker on ADS-TEC IRF
# devices. Modbus TCP clients connect to TCP_PORT; mbusd forwards the requests
# to the RTU slaves on the serial port (the IRF RS485 interface) and returns
# the responses.
#
# The IRF hands its RS485 port into Docker when "Access to RS485" is enabled
# on the Docker settings page; start the container with --device <port>.
set -euo pipefail

SERIAL_DEVICE="${SERIAL_DEVICE:-/dev/ttyS1}"
SERIAL_SPEED="${SERIAL_SPEED:-19200}"
SERIAL_MODE="${SERIAL_MODE:-8E1}"          # Modbus RTU default: 8 data bits, even parity, 1 stop bit
TCP_ADDRESS="${TCP_ADDRESS:-0.0.0.0}"
TCP_PORT="${TCP_PORT:-502}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-32}"
RETRIES="${RETRIES:-3}"
PAUSE_MS="${PAUSE_MS:-100}"                 # pause between requests
WAIT_MS="${WAIT_MS:-500}"                   # response timeout per request
CONN_TIMEOUT="${CONN_TIMEOUT:-60}"          # idle TCP connection timeout (s)
REPLY_ON_BROADCAST="${REPLY_ON_BROADCAST:-no}"
LOG_LEVEL="${LOG_LEVEL:-1}"                 # 0 errors, 1 warnings, 2 info

if [[ ! -c "${SERIAL_DEVICE}" ]]; then
    echo "ERROR: ${SERIAL_DEVICE} is not available in the container." >&2
    echo "  Enable \"Access to RS485\" on the IRF Docker settings page and start" >&2
    echo "  the container with --device ${SERIAL_DEVICE}." >&2
    exit 1
fi

args=(-d -L - -v "${LOG_LEVEL}"
      -p "${SERIAL_DEVICE}" -s "${SERIAL_SPEED}" -m "${SERIAL_MODE}"
      -A "${TCP_ADDRESS}" -P "${TCP_PORT}" -C "${MAX_CONNECTIONS}"
      -N "${RETRIES}" -R "${PAUSE_MS}" -W "${WAIT_MS}" -T "${CONN_TIMEOUT}"
      # RS485 transmitter: RTS active while transmitting, switched by mbusd.
      # Fixed by the IRF hardware, same as the IRF's own Modbus RTU client
      # (libmodbus MODBUS_RTU_RTS_UP, no kernel RS485 mode). Not configurable.
      -t)
[[ "${REPLY_ON_BROADCAST}" == "yes" ]] && args+=(-b)

echo "=== Modbus TCP to RTU gateway (mbusd $(mbusd -h 2>&1 | sed -n 's/.*mbusd-\([0-9.]*\).*/\1/p' | head -1)) ==="
echo "  Modbus TCP: ${TCP_ADDRESS}:${TCP_PORT} (max. ${MAX_CONNECTIONS} connections)"
echo "  Modbus RTU: ${SERIAL_DEVICE} ${SERIAL_SPEED} ${SERIAL_MODE}, RS485 direction via RTS"
echo "  Timing:     wait ${WAIT_MS} ms, pause ${PAUSE_MS} ms, ${RETRIES} retries"

exec mbusd "${args[@]}"
