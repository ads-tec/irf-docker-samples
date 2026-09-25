# Samba Active Directory Domain Controller for ADS-TEC IRF3000

Sample container by **ADS-TEC Industrial IT**: Samba 4.22 (Debian trixie) as Active Directory domain controller in the rootless Docker of the IRF3000 industrial firewalls.

Provides DNS, Kerberos, LDAP/LDAPS, Global Catalog, `sysvol`/`netlogon` for group policies and the RPC services for an OT segment. Clients reach the domain controller at the IRF LAN address; the IRF forwards the AD ports into the container.

Rootless Docker on the IRF cannot store the extended attributes and POSIX ACLs a standard Samba DC needs. This image stores the file ACLs of `sysvol` in a Samba database (`vfs_xattr_tdb` with stable `vfs_fileid` keys) and adapts the ID range to the rootless user mapping.

## Quick start

```bash
docker run -d --name samba-dc --hostname dc1 --restart unless-stopped \
  --network host -v samba-dc-data:/var/lib/samba \
  -e REALM=IRF.LAN -e DOMAIN=IRF -e DC_HOSTNAME=DC1 \
  -e HOST_IP=192.168.0.254 \
  adstec/irf-samba-dc
docker logs samba-dc | grep -A2 "Generated Administrator password"
```

No `--privileged`, no additional capabilities.

| Variable | Default | Meaning |
|---|---|---|
| `REALM` | `IRF.LAN` | Kerberos realm / DNS domain |
| `DOMAIN` | `IRF` | NetBIOS domain name |
| `DC_HOSTNAME` | `DC1` | Host name of the DC |
| `ADMIN_PASSWORD` | random, printed once to the log | `Administrator` password |
| `HOST_IP` | `192.168.0.254` | Address registered in DNS - the IRF address clients use |
| `DNS_FORWARDER` | DNS server of the IRF | Upstream DNS |
| `RPC_PORT_RANGE` | `49152-49172` | Dynamic RPC ports, must match the port forwarding |
| `SYSVOL_RESET` | `0` | `1` re-applies the sysvol ACLs, e.g. after a restore |

The IRF has to forward DNS, Kerberos, RPC, NetBIOS, LDAP, SMB, kpasswd, LDAPS, Global Catalog and the dynamic RPC range to the container. Setup, port forwarding, backup rules and an assessment of the database-based ACL storage are described in the **Docker Application Note** of ADS-TEC Industrial IT.

## Files

Dockerfile, entrypoint.sh, docker-compose.yml, setup_forwarding.py

## Build from source

Build on a workstation for the IRF architecture and load the image onto the IRF through its Docker socket (the IRF itself does not need internet access):

```bash
docker buildx build --platform linux/arm64 -t irf-samba-dc --load .
docker save irf-samba-dc | DOCKER_HOST=tcp://192.168.0.254:2375 docker load
```

Use `--platform linux/arm/v7` for ARMv7 devices. Behind an HTTP proxy, pass `--build-arg HTTP_PROXY=... --build-arg HTTPS_PROXY=...`; the proxy is not stored in the image.

## Configure the IRF

`setup_forwarding.py` applies the IRF settings for this sample through the JSON-RPC API and saves them. It needs `jsonrpcdevice.py` from [ads-tec/Python-AdstecJSONRPCDevice](https://github.com/ads-tec/Python-AdstecJSONRPCDevice) (next to the script or on `PYTHONPATH`) and `pip install requests`:

```bash
python3 setup_forwarding.py --device 192.168.0.254
python3 setup_forwarding.py --help
```

The password is asked for if `--password` is omitted. The same settings can be made in the IRF web interface as described in the Docker Application Note.

## Links

- [IRF3000 industrial firewall](https://www.ads-tec-iit.com/en/reliable-remote-access/firewall-router/irf3000/) - product page of ADS-TEC Industrial IT

## Platforms and license

`linux/arm64` (IRF3000), `linux/arm/v7`. Samba is licensed under GPLv3.
