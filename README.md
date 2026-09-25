# Docker samples for ADS-TEC IRF industrial firewalls

Sample containers by **ADS-TEC Industrial IT** for the rootless Docker of the IRF3000 (and, where noted, IRF1000) industrial firewalls. Each folder contains everything to build the image and to configure the IRF for it. Prebuilt multi-architecture images (`linux/arm64`, `linux/arm/v7`) are available on Docker Hub.

| Folder | Purpose | Docker Hub |
|---|---|---|
| [`samba-dc`](samba-dc/) | Samba 4 Active Directory domain controller for an OT segment | [`adstec/irf-samba-dc`](https://hub.docker.com/r/adstec/irf-samba-dc) |
| [`syslog`](syslog/) | syslog-ng log collector with size cap and read-only SSH log access (lnav, ripgrep) | [`adstec/irf-syslog`](https://hub.docker.com/r/adstec/irf-syslog) |
| [`modbus-gw`](modbus-gw/) | Modbus RTU (RS-485) to Modbus TCP converter (mbusd) | [`adstec/irf-modbus-gw`](https://hub.docker.com/r/adstec/irf-modbus-gw) |
| [`smb-proxy`](smb-proxy/) | SMBv1 to SMB3 live proxy for legacy file shares, plus an SMBv1 test server | [`adstec/irf-smb-proxy`](https://hub.docker.com/r/adstec/irf-smb-proxy), [`adstec/irf-smb-xp-sim`](https://hub.docker.com/r/adstec/irf-smb-xp-sim) |

The setup, the IRF configuration in the web interface and the background of each sample are described in the **Docker Application Note** of ADS-TEC Industrial IT.

## Common to all samples

- **Rootless Docker.** The containers run without `--privileged` (except the SMB proxy, which needs FUSE) and are started with `--network host`, i.e. in the rootless network namespace of the IRF.
- **Reaching the container.** The Docker DHCP pool of the IRF is pinned to a single address (`10.0.3.100` in the examples), and the IRF forwards the service ports from its LAN or WAN interface to that address.
- **Saving.** Settings made through the web interface or the JSON-RPC API are lost on the next reboot unless they are saved ("System > Save Settings").
- **Building.** Build on a workstation for the IRF architecture and load the image through the Docker socket of the IRF; the IRF itself does not need internet access:

  ```bash
  docker buildx build --platform linux/arm64 -t <image> --load <folder>
  docker save <image> | DOCKER_HOST=tcp://192.168.0.254:2375 docker load
  ```

## IRF setup scripts

Each folder has a `setup_forwarding.py` that enables Docker, pins the Docker DHCP pool, creates the port-forwarding rules of the sample and saves the settings through the IRF JSON-RPC API. Requirements:

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

The images contain third-party open-source software under its own licenses, among others Samba (GPLv3), syslog-ng (LGPL/GPL), smbnetfs (GPLv2) and mbusd (BSD 3-Clause, source included in `modbus-gw/src/`). The base images (Debian, Alpine) and their packages are available from the respective distributions.

These are sample containers: they show how a use case can be implemented on the IRF and are provided as is.
