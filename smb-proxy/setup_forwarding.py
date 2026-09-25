#!/usr/bin/env python3
# Copyright (c) 2026, ads-tec Industrial IT GmbH
# SPDX-License-Identifier: BSD-2-Clause
"""Configure an ADS-TEC IRF for the SMBv1 to SMB3 proxy sample (or the XP simulator).

Enables Docker, pins the Docker DHCP pool to a single address and forwards
SMB (tcp/445) from the given interface to the container. For the proxy this
is the interface facing the modern clients (default: WAN). --netbios also
forwards tcp/139, which only real SMBv1 clients of the XP simulator need.

Requires the ads-tec JSON-RPC client library (jsonrpcdevice.py) and requests:
    https://github.com/ads-tec/Python-AdstecJSONRPCDevice
    pip install requests

Settings changed through the JSON-RPC API are only applied until the next
reboot unless they are saved; this script saves them at the end (--no-save
skips that).

Examples:
    python3 setup_forwarding.py --device 192.168.0.254                    # proxy, WAN side
    python3 setup_forwarding.py --device 192.168.0.1 --interface br0 --netbios   # XP simulator, LAN side
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

COMMENT_PREFIX = "SMB"

# (proto, port or range, service)
PORTS = [
    ("tcp", "445", "SMB"),
]
NETBIOS = ("tcp", "139", "NetBIOS SSN")
ALL_PORTS = PORTS + [NETBIOS]


def comment(proto, service):
    return f"{COMMENT_PREFIX} {service} {proto}"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--device", default="192.168.0.254", help="IRF address (default: %(default)s)")
    p.add_argument("--user", default="admin", help="IRF user (default: %(default)s)")
    p.add_argument("--password", help="IRF password (asked for if omitted)")
    p.add_argument("--interface", help="Linux interface name to forward from "
                   "(default: the IRF WAN interface, config variable wan_ifname)")
    p.add_argument("--docker-ip", default="10.0.3.100",
                   help="address of the Docker namespace, pinned via Docker DHCP (default: %(default)s)")
    p.add_argument("--no-save", action="store_true", help="apply the settings, but do not save them")
    p.add_argument("--netbios", action="store_true", help="also forward tcp/139 (XP simulator)")
    return p.parse_args()


def main():
    args = parse_args()
    password = args.password or getpass.getpass(f"Password for {args.user}@{args.device}: ")
    dev = jsonrpcdevice.AdstecJSONRPCDevice(args.device, args.user, password)
    ifname = args.interface or dev.config_get(["wan_ifname"])["result"][0]["wan_ifname"]
    ports = PORTS + ([NETBIOS] if args.netbios else [])

    cfg = dev.sess_start()

    # Enable Docker and pin the Docker DHCP pool to one address, so the
    # forwarding target stays stable
    settings = {
        "docker_status": "enabled",
        "dhcp_startip_docker": args.docker_ip,
        "dhcp_endip_docker": args.docker_ip,
    }
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
            "",                  # fwsrcnet
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

    if not args.no_save:
        dev.config_set_commit({"save_now": "1"})
        print("Settings saved.")
    else:
        print("Settings applied, NOT saved - they are lost on the next reboot.")
    dev.logout()


if __name__ == "__main__":
    main()
