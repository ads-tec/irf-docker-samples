# syslog-ng Log Collector for ADS-TEC IRF3000

Sample container by **ADS-TEC Industrial IT**: syslog-ng 4.8 (Alpine) as central syslog collector in the rootless Docker of the IRF3000 industrial firewalls, with a size-capped log archive and read-only log access over SSH.

- Receives syslog on UDP/TCP 514 (RFC 3164 and RFC 5424, detected automatically), TCP 601 (RFC 5424) and TCP 6514 (TLS, RFC 5425)
- One file per sender and hour, compressed after the hour
- Size cap and retention period, enforced by the container (Docker cannot size-limit volumes on the IRF)
- SSH on port 2222 for user `logs` with `lnav`, `ripgrep` and `sftp` - read-only, no root login, no forwarding
- Self-signed TLS certificate, SSH host keys and the generated SSH password are kept in the volume

## Quick start

```bash
docker run -d --name syslog --hostname syslog --restart unless-stopped \
  --network host -v syslog-data:/var/log/remote \
  -e LOG_MAX_SIZE=1G -e LOG_RETENTION_DAYS=90 -e TZ=Europe/Berlin \
  adstec/irf-syslog
docker exec syslog cat /var/log/remote/.sshd/password
ssh -p 2222 logs@<irf-address>
```

No `--privileged`, no additional capabilities.

| Variable | Default | Meaning |
|---|---|---|
| `LOG_MAX_SIZE` | `1G` | Total size cap of the log volume |
| `LOG_RETENTION_DAYS` | `90` | Files older than this are deleted |
| `TZ` | `UTC` | Time zone for RFC 3164 messages and file names |
| `TLS` | `yes` | Syslog over TLS on TCP 6514 |
| `SSH` | `yes` | SSH log access |
| `SSH_PORT` | `2222` | SSH port |
| `SSH_PASSWORD` | random, printed once | Password of user `logs` |
| `SSH_AUTHORIZED_KEYS` | empty | Public key(s); with a key and no password, password login is disabled |

Setup, port forwarding and sending the IRF's own event and audit log to the collector are described in the **Docker Application Note** of ADS-TEC Industrial IT.

## Files

Dockerfile, entrypoint.sh, syslog-ng.conf, log-retention.sh, motd, docker-compose.yml, setup_forwarding.py

## Build from source

Build on a workstation for the IRF architecture and load the image onto the IRF through its Docker socket (the IRF itself does not need internet access):

```bash
docker buildx build --platform linux/arm64 -t irf-syslog --load .
docker save irf-syslog | DOCKER_HOST=tcp://192.168.0.254:2375 docker load
```

Use `--platform linux/arm/v7` for ARMv7 devices. Behind an HTTP proxy, pass `--build-arg HTTP_PROXY=... --build-arg HTTPS_PROXY=...`; the proxy is not stored in the image.

## Configure the IRF

`setup_forwarding.py` applies the IRF settings for this sample through the JSON-RPC API and saves them. It needs `jsonrpcdevice.py` from [ads-tec/Python-AdstecJSONRPCDevice](https://github.com/ads-tec/Python-AdstecJSONRPCDevice) (next to the script or on `PYTHONPATH`) and `pip install requests`:

```bash
python3 setup_forwarding.py --device 192.168.0.254 --irf-logs
python3 setup_forwarding.py --help
```

The password is asked for if `--password` is omitted. The same settings can be made in the IRF web interface as described in the Docker Application Note.

## Links

- [IRF3000 industrial firewall](https://www.ads-tec-iit.com/en/reliable-remote-access/firewall-router/irf3000/) - product page of ADS-TEC Industrial IT

## Platforms and license

`linux/arm64` (IRF3000), `linux/arm/v7`. syslog-ng is licensed under LGPL/GPL.
