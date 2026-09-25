# SMBv1 to SMB3 Transparent Proxy for ADS-TEC IRF1000 / IRF3000

Sample container by **ADS-TEC Industrial IT**: bridges a legacy file share that only speaks SMBv1 (e.g. a Windows XP machine in the OT segment) to modern SMB2/SMB3 clients in the IT network.

The container mounts the legacy share with the userspace SMB client `smbnetfs` (FUSE) and re-exports it with Samba as SMB2/SMB3 share `xp-share`. It is a live pass-through, not a sync job: files written on either side appear immediately on the other, the IRF keeps no copy. The IRF firmware contains no kernel CIFS client, so `mount -t cifs` is not used.

## Quick start

```bash
docker run -d --name samba-proxy --restart always \
  --network host --privileged --device /dev/fuse --security-opt label=disable \
  -e SMB_HOST=192.168.0.1 -e SMB_SHARE=SharedFolder \
  -e SMB_USER=xpuser -e SMB_PASS=<legacy-password> -e SMB_WORKGROUP=WORKGROUP \
  -e LOCAL_USER=smbuser -e LOCAL_PASSWORD=<new-password> \
  -e WAIT_TIMEOUT=60 \
  adstec/irf-smb-proxy
```

| Variable | Meaning |
|---|---|
| `SMB_HOST`, `SMB_SHARE` | Legacy SMBv1 server and share |
| `SMB_USER`, `SMB_PASS`, `SMB_WORKGROUP` | Credentials on the legacy side |
| `LOCAL_USER`, `LOCAL_PASSWORD` | Credentials modern clients use for `\\<irf>\xp-share` |
| `WAIT_TIMEOUT` | Seconds to wait for the legacy share at start |

Modern clients connect to TCP port 445 of the IRF, which the IRF forwards to the container. Setup, port forwarding and known issues are described in the **Docker Application Note** of ADS-TEC Industrial IT.

See also `adstec/irf-smb-xp-sim`, an SMBv1 test server for lab setups.

## SMBv1 Windows XP File Server Simulator (lab use only)

Sample container by **ADS-TEC Industrial IT**: a small Alpine/Samba server that stands in for a legacy Windows XP file server when testing `adstec/irf-smb-proxy` without real legacy hardware.

It exports the share `SharedFolder` over **SMBv1/NT1 only**, pre-populated with a few test files (`testfile.txt`, `document.txt`, `subfolder/nested.txt`).

> **For lab and proof-of-concept use only.** The image runs SMBv1 deliberately, has hard-coded test content and no domain integration. Do not deploy it in a production network.

### Quick start

```bash
docker run -d --name xp-sim --restart always --network host \
  -e XP_PASSWORD=<test-password> \
  adstec/irf-smb-xp-sim
```

User `xpuser`, share `SharedFolder`, TCP ports 445 and 139.

Run it on a **separate** IRF (or another host), not on the IRF that runs the proxy: the simulator has to appear on the LAN at the address of the legacy server, and both containers would need the same SMB port in the rootless Docker namespace. Details are in the **Docker Application Note** of ADS-TEC Industrial IT.

## Files

Dockerfile, entrypoint.sh, smb.conf (proxy); Dockerfile.xp-sim, entrypoint-xp.sh, smb-xp.conf (XP simulator); docker-compose.yml, setup_forwarding.py

## Build from source

Build on a workstation for the IRF architecture and load the image onto the IRF through its Docker socket (the IRF itself does not need internet access):

```bash
docker buildx build --platform linux/arm64 -t irf-smb-proxy --load .
docker buildx build --platform linux/arm64 -f Dockerfile.xp-sim -t irf-smb-xp-sim --load .   # XP simulator
docker save irf-smb-proxy | DOCKER_HOST=tcp://192.168.0.254:2375 docker load
```

Use `--platform linux/arm/v7` for ARMv7 devices. Behind an HTTP proxy, pass `--build-arg HTTP_PROXY=... --build-arg HTTPS_PROXY=...`; the proxy is not stored in the image.

## Configure the IRF

`setup_forwarding.py` applies the IRF settings for this sample through the JSON-RPC API and saves them. It needs `jsonrpcdevice.py` from [ads-tec/Python-AdstecJSONRPCDevice](https://github.com/ads-tec/Python-AdstecJSONRPCDevice) (next to the script or on `PYTHONPATH`) and `pip install requests`:

```bash
python3 setup_forwarding.py --device 192.168.0.254            # proxy, WAN side
python3 setup_forwarding.py --help
```

The password is asked for if `--password` is omitted. The same settings can be made in the IRF web interface as described in the Docker Application Note.

## Links

- [IRF3000 industrial firewall](https://www.ads-tec-iit.com/en/reliable-remote-access/firewall-router/irf3000/) - product page of ADS-TEC Industrial IT

## Platforms and license

`linux/arm64` (IRF3000), `linux/arm/v7` (IRF1000). Samba is licensed under GPLv3, smbnetfs under GPLv2.
