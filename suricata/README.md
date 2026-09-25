# Suricata IDS Demo for ADS-TEC IRF3000

Demo container by **ADS-TEC Industrial IT**: Suricata 7 (Alpine) as intrusion detection system on the **Docker Monitor Port** of the IRF3000 industrial firewalls. Together with the [EveBox](https://evebox.org/) web frontend it lets you evaluate IDS rule sets with your own network traffic.

> **For evaluation and testing only**, not for production IDS deployments. For professional deployments, contact ADS-TEC Industrial IT.

- Captures on the Monitor interface that the IRF moves into containers started with `--label monitor=yes`
- Alerts and events in `/var/log/suricata/eve.json` for EveBox (shared volume)
- Emerging Threats Open rules, updated at start and daily; a failed download keeps the current rules
- Pattern matching with Vectorscan (Hyperscan for ARM)
- SSH for user `adstec` with a generated password (`htop`, `tcpdump`, logs) - no root login
- Log files rotated at 200 MB

## Quick start

On the IRF: set a port to "Monitor" (operating mode "IP router (extended)") and enable the Monitor interfaces on the Docker page. Then:

```bash
docker run -d --name suricata --label monitor=yes --restart unless-stopped \
  -p 2222:22 -e IDS_INTERFACE=ETH2 \
  -v suricata-logs:/var/log/suricata -v suricata-data:/var/lib/suricata \
  adstec/irf3000-ids-demo-suricata
docker logs suricata | grep -A1 "Generated SSH password"

docker run -d --name evebox --restart unless-stopped -p 5636:5636 \
  -v evebox-data:/var/lib/evebox -v suricata-logs:/var/log/suricata:ro \
  jasonish/evebox:latest \
  evebox server -D /var/lib/evebox --sqlite --input /var/log/suricata/eve.json --host 0.0.0.0
docker logs evebox | grep "Created administrator"   # then https://<irf>:5636
```

Loading the full Emerging Threats Open rule set (about 50,000 rules) takes about 3 minutes and about 450 MB RAM on an IRF3000.

| Variable | Default | Meaning |
|---|---|---|
| `IDS_INTERFACE` | `ETH2` | Monitor interface |
| `HOME_NET` | from `suricata.yaml` | Protected networks, e.g. `[192.168.0.0/24]` |
| `RULE_UPDATE` | `yes` | Rule update at start and daily |
| `RULE_URL` | Emerging Threats Open | Rule source, e.g. a local mirror for IRFs without internet |
| `HTTPS_PROXY` | - | Proxy for the rule download |
| `LOG_MAX_SIZE` | `200M` | Rotation size per log file |
| `SSH_PASSWORD` / `SSH_AUTHORIZED_KEYS` | generated / - | Login of user `adstec` |

Arguments are passed to Suricata; without arguments it runs `-i $IDS_INTERFACE`.

## Files

Dockerfile, entrypoint.sh, update-rules.sh (rule update that keeps the current rules if the download fails), suricata.yaml (capture interface and `HOME_NET` are set at start), docker-compose.yml (Suricata + EveBox)

## Build from source

Build on a workstation and load the image onto the IRF through its Docker socket (the IRF itself does not need internet access):

```bash
docker buildx build --platform linux/arm64 -t irf3000-ids-demo-suricata --load .
docker save irf3000-ids-demo-suricata | DOCKER_HOST=tcp://192.168.0.254:2375 docker load
```

Behind an HTTP proxy, pass `--build-arg HTTP_PROXY=... --build-arg HTTPS_PROXY=...`; the proxy is not stored in the image.

## Configure the IRF

No port forwarding is needed: SSH (2222) and EveBox (5636) are published with `-p`. On the IRF:

1. Set the operating mode to "IP router (extended)" and one port to "Monitor" (IP configuration page).
2. Enable the Monitor interfaces on the Docker page ("Configuration > Services > Docker").
3. Save the settings ("System > Save Settings").
4. Start the containers with `docker compose up -d` (set `IDS_INTERFACE` to your Monitor port).

The rule update needs internet access from the container; set `HTTPS_PROXY` if a proxy is required, or `RULE_URL` for a local copy of the rule archive. Details are in the Docker Application Note.

## Links

- [IRF3000 industrial firewall](https://www.ads-tec-iit.com/en/reliable-remote-access/firewall-router/irf3000/) - product page of ADS-TEC Industrial IT

## Platforms and license

`linux/arm64` (IRF3000). Suricata is licensed under GPLv2, Vectorscan under the BSD 3-Clause license.
