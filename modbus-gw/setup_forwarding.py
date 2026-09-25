#!/usr/bin/env python3
# Copyright (c) 2026, ads-tec Industrial IT GmbH
# SPDX-License-Identifier: BSD-2-Clause
"""Configure an ADS-TEC IRF3000 for the Modbus RTU to Modbus TCP converter sample.

Enables Docker and "Access to RS485", pins the Docker DHCP pool to a single
address and forwards Modbus TCP (tcp/502) from the LAN interface to the
container. Modbus TCP has no authentication: use --srcnet to accept
connections only from the network of your SCADA/HMI systems.

Enabling "Access to RS485" restarts the Docker service. If Docker is not
reachable again after a minute, restart the IRF.

Requires the ads-tec JSON-RPC client library (jsonrpcdevice.py) and requests:
    https://github.com/ads-tec/Python-AdstecJSONRPCDevice
    pip install requests

Settings changed through the JSON-RPC API are only applied until the next
reboot unless they are saved; this script saves them at the end (--no-save
skips that).

Examples:
    python3 setup_forwarding.py --device 192.168.0.254 --srcnet 192.168.0.0/24
"""

import argparse
import getpass
import sys

try:
    import jsonrpcdevice
except ImportError:
    sys.exit("jsonrpcdevice.py not found - download it from "
             "https://github.com/ads-tec/Python-AdstecJSONRPCDevice and put it "
             "next to this script or on PYTHONPATH")

COMMENT_PREFIX = "Modbus"

# (proto, port or range, service)
PORTS = [
    ("tcp", "502", "TCP gateway"),
]
ALL_PORTS = PORTS


def comment(proto, service):
    return f"{COMMENT_PREFIX} {service} {proto}"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--device", default="192.168.0.254", help="IRF address (default: %(default)s)")
    p.add_argument("--user", default="admin", help="IRF user (default: %(default)s)")
    p.add_argument("--password", help="IRF password (asked for if omitted)")
    p.add_argument("--interface", help="Linux interface name to forward from "
                   "(default: the IRF LAN interface, config variable lan_ifname)")
    p.add_argument("--docker-ip", default="10.0.3.100",
                   help="address of the Docker namespace, pinned via Docker DHCP (default: %(default)s)")
    p.add_argument("--no-save", action="store_true", help="apply the settings, but do not save them")
    p.add_argument("--srcnet", default="",
                   help="accept Modbus TCP only from this network, e.g. 192.168.0.0/24 (recommended)")
    return p.parse_args()


def main():
    args = parse_args()
    password = args.password or getpass.getpass(f"Password for {args.user}@{args.device}: ")
    dev = jsonrpcdevice.AdstecJSONRPCDevice(args.device, args.user, password)
    ifname = args.interface or dev.config_get(["lan_ifname"])["result"][0]["lan_ifname"]
    ports = PORTS

    cfg = dev.sess_start()

    # Enable Docker and pin the Docker DHCP pool to one address, so the
    # forwarding target stays stable
    settings = {
        "docker_status": "enabled",
        "dhcp_startip_docker": args.docker_ip,
        "dhcp_endip_docker": args.docker_ip,
    }
    settings["docker_use_rs485_device"] = "enabled"
    dev.config_set(cfg, settings)

    # Replace the rules of this sample, append them after all other rules
    for proto, _, service in ALL_PORTS:
        try:
            dev.table_del("forwarding", cfg, condition={"fwcomment": comment(proto, service)})
        except Exception:
            pass
    existing = dev.call("config", "table_get", tablename="forwarding", condition={})["forwarding"]
    first = len([r for r in existing if not r["fwcomment"].startswith(COMMENT_PREFIX + " ")]) + 1

    for position, (proto, port, service) in enumerate(ports, start=first):
        dev.table_insert("forwarding", cfg, [
            ifname,                  # fwifname
            proto,                   # fwproto
            "",                      # fwlocalip
            port,                    # fwlocalport
            args.docker_ip,          # fwtargetip
            port,                    # fwtargetport
            "enabled",               # fwsnat: the Docker namespace has no route back to the clients
            args.srcnet,                  # fwsrcnet
            comment(proto, service), # fwcomment
            "enabled",               # fwenabled
            str(position),           # fwposition
            "disabled",              # fwrsnat
        ])
    dev.sess_commit(cfg)

    rules = dev.call("config", "table_get", tablename="forwarding", condition={})["forwarding"]
    print(f"Forwarding rules on {ifname} -> {args.docker_ip}:")
    for r in rules:
        if r["fwcomment"].startswith(COMMENT_PREFIX + " "):
            src = f" from {r['fwsrcnet']}" if r.get("fwsrcnet") else ""
            print(f"  {r['fwproto']}/{r['fwlocalport']}{src} -> {r['fwtargetip']}:{r['fwtargetport']}")
    if not args.srcnet:
        print("WARNING: tcp/502 is reachable from every network on this interface (see --srcnet)")

    if not args.no_save:
        dev.config_set_commit({"save_now": "1"})
        print("Settings saved.")
    else:
        print("Settings applied, NOT saved - they are lost on the next reboot.")
    dev.logout()


if __name__ == "__main__":
    main()
