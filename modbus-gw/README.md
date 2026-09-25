# Modbus RTU to Modbus TCP Converter for ADS-TEC IRF3000

Sample container by **ADS-TEC Industrial IT**: the open-source gateway [mbusd](https://github.com/3cky/mbusd) in the rootless Docker of the IRF3000 industrial firewalls. Modbus TCP clients (SCADA, HMI, PLC) connect to the IRF on TCP port 502; the gateway forwards the requests to the Modbus RTU slaves on the integrated RS-485 interface.

- The unit identifier of the Modbus TCP request selects the RTU slave
- Several clients at the same time, requests are serialized on the bus
- RS-485 direction switching is handled by the container
- Exception 0x0B (Gateway Target Device Failed to Respond) if a slave does not answer

## Quick start

Enable **Access to RS485** under "Configuration > Services > Docker" on the IRF, then:

```bash
docker run -d --name modbus-gw --restart unless-stopped \
  --network host --device /dev/ttyS1 \
  -e SERIAL_SPEED=19200 -e SERIAL_MODE=8E1 \
  adstec/irf-modbus-gw
```

| Variable | Default | Meaning |
|---|---|---|
| `SERIAL_DEVICE` | `/dev/ttyS1` | RS-485 interface in the container |
| `SERIAL_SPEED` | `19200` | Baud rate |
| `SERIAL_MODE` | `8E1` | Data bits, parity (`N`/`E`/`O`), stop bits |
| `TCP_PORT` | `502` | Modbus TCP port |
| `WAIT_MS` | `500` | Response timeout per request (ms) |
| `RETRIES` | `3` | Retries per request |
| `LOG_LEVEL` | `1` | `0` errors, `1` warnings, `2` connections |

**Modbus TCP has no authentication.** Restrict the IRF forwarding rule for port 502 to the network of your SCADA/HMI systems and never forward it from a WAN interface. Setup and port forwarding are described in the **Docker Application Note** of ADS-TEC Industrial IT.

## Files

Dockerfile, entrypoint.sh, src/mbusd-0.5.3.tar.gz, docker-compose.yml, setup_forwarding.py, test/ (RTU slave simulator and TCP client for a virtual serial port pair)

## Build from source

The mbusd source tarball is included in `src/`; the `Dockerfile` verifies its SHA-256 before building.

Build on a workstation for the IRF architecture and load the image onto the IRF through its Docker socket (the IRF itself does not need internet access):

```bash
docker buildx build --platform linux/arm64 -t irf-modbus-gw --load .
docker save irf-modbus-gw | DOCKER_HOST=tcp://192.168.0.254:2375 docker load
```

Use `--platform linux/arm/v7` for ARMv7 devices. Behind an HTTP proxy, pass `--build-arg HTTP_PROXY=... --build-arg HTTPS_PROXY=...`; the proxy is not stored in the image.

## Configure the IRF

`setup_forwarding.py` applies the IRF settings for this sample through the JSON-RPC API and saves them. It needs `jsonrpcdevice.py` from [ads-tec/Python-AdstecJSONRPCDevice](https://github.com/ads-tec/Python-AdstecJSONRPCDevice) (next to the script or on `PYTHONPATH`) and `pip install requests`:

```bash
python3 setup_forwarding.py --device 192.168.0.254 --srcnet 192.168.0.0/24
python3 setup_forwarding.py --help
```

The password is asked for if `--password` is omitted. The same settings can be made in the IRF web interface as described in the Docker Application Note.

## Links

- [IRF3000 industrial firewall](https://www.ads-tec-iit.com/en/reliable-remote-access/firewall-router/irf3000/) - product page of ADS-TEC Industrial IT

## Platforms and license

`linux/arm64` (IRF3000), `linux/arm/v7`. mbusd is licensed under the BSD 3-Clause license.
