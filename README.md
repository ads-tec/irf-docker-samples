# Docker samples for ADS-TEC IRF industrial firewalls

Sample containers by **ADS-TEC Industrial IT** for the rootless Docker of the IRF3000 (and, where noted, IRF1000) industrial firewalls. Each folder contains everything to build the image and to configure the IRF for it. Prebuilt images are available on Docker Hub (`linux/arm64` for the IRF3000, most samples also `linux/arm/v7`).

| Folder | Purpose | Docker Hub |
|---|---|---|
| [`samba-dc`](samba-dc/) | Samba 4 Active Directory domain controller for an OT segment | [`adstec/irf-samba-dc`](https://hub.docker.com/r/adstec/irf-samba-dc) |
| [`syslog`](syslog/) | syslog-ng log collector with size cap and read-only SSH log access (lnav, ripgrep) | [`adstec/irf-syslog`](https://hub.docker.com/r/adstec/irf-syslog) |
| [`modbus-gw`](modbus-gw/) | Modbus RTU (RS-485) to Modbus TCP converter (mbusd) | [`adstec/irf-modbus-gw`](https://hub.docker.com/r/adstec/irf-modbus-gw) |
| [`smb-proxy`](smb-proxy/) | SMBv1 to SMB3 live proxy for legacy file shares, plus an SMBv1 test server | [`adstec/irf-smb-proxy`](https://hub.docker.com/r/adstec/irf-smb-proxy), [`adstec/irf-smb-xp-sim`](https://hub.docker.com/r/adstec/irf-smb-xp-sim) |
| [`capture`](capture/) | Packet capture via the IRF's remote capture server: live capture in the browser (webshark), tshark over SSH | build from source |
| [`suricata`](suricata/) | Suricata IDS demo on the Docker Monitor Port, with EveBox web frontend (IRF3000 only) | [`adstec/irf3000-ids-demo-suricata`](https://hub.docker.com/r/adstec/irf3000-ids-demo-suricata) |

The setup, the IRF configuration in the web interface and the background of each sample are described in the **Docker Application Note** of ADS-TEC Industrial IT.

## Common to all samples

- **Rootless Docker.** The containers run without `--privileged` (except the SMB proxy, which needs FUSE). The samples with port forwarding use `--network host`, i.e. the rootless network namespace of the IRF; the Suricata sample uses the default bridge network.
- **Reaching the container.** Services on standard ports below 1024 (DNS, SMB, syslog, Modbus, ...) need port forwarding: the Docker DHCP pool of the IRF is pinned to a single address (`10.0.3.100` in the examples), and the IRF forwards the service ports from its LAN or WAN interface to that address. In operating mode "IP router (extended)" the packet filter must also allow the forwarded traffic. Ports above 1024 can be published with `docker run -p` instead (Suricata sample).
- **Saving.** Settings made through the web interface or the JSON-RPC API are lost on the next reboot unless they are saved ("System > Save Settings").
- **Building.** Build on a workstation for the IRF architecture and load the image through the Docker socket of the IRF; the IRF itself does not need internet access:

  ```bash
  docker buildx build --platform linux/arm64 -t <image> --load <folder>
  docker save <image> | DOCKER_HOST=tcp://192.168.0.254:2375 docker load
  ```

## IRF setup scripts

The samples with port forwarding have a `setup_forwarding.py` (the capture sample: `setup_rpcap.py`) that enables Docker, pins the Docker DHCP pool, creates the port-forwarding rules of the sample and saves the settings through the IRF JSON-RPC API. Requirements:

- `jsonrpcdevice.py` from [ads-tec/Python-AdstecJSONRPCDevice](https://github.com/ads-tec/Python-AdstecJSONRPCDevice), next to the script or on `PYTHONPATH`
- `pip install requests`

```bash
python3 samba-dc/setup_forwarding.py --device 192.168.0.254
python3 samba-dc/setup_forwarding.py --help
```

The password is asked for if `--password` is omitted. `--no-save` applies the settings without saving them.

## Links

- [IRF3000 industrial firewall](https://www.ads-tec-iit.com/en/reliable-remote-access/firewall-router/irf3000/) - product page of ADS-TEC Industrial IT
- [ads-tec IRF JSON-RPC API](https://ads-tec.github.io/Python-AdstecJSONRPCDevice/) - API documentation and Python client

## License

The files in this repository are licensed under the BSD 2-Clause license, see [LICENSE](LICENSE).

The images contain third-party open-source software under its own licenses, among others Samba (GPLv3), syslog-ng (LGPL/GPL), smbnetfs (GPLv2), Suricata (GPLv2), Vectorscan (BSD 3-Clause) and mbusd (BSD 3-Clause, source included in `modbus-gw/src/`). The base images (Debian, Alpine) and their packages are available from the respective distributions.

These are sample containers: they show how a use case can be implemented on the IRF and are provided as is.
