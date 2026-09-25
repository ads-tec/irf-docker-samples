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


def default_interface(dev, address, fallback_var):
    """Linux interface that holds the given IRF address.

    In "IP router (extended)" mode the LAN address is on a port interface
    (e.g. lan_port1 = ETH2) and lan_ifname still names the unused bridge, so
    look up the symbolic interface whose IP address matches.
    """
    symbolic = dev.status("symbolic_ifnames_with_umts_with_ipsec").split()
    for name in symbolic:
        try:
            res = dev.config_get([f"{name}_ipaddr", f"{name}_ifname"])["result"]
        except Exception:
            continue
        values = {k: v for d in res for k, v in d.items()}
        if values.get(f"{name}_ipaddr") == address and values.get(f"{name}_ifname"):
            return values[f"{name}_ifname"]
    return dev.config_get([fallback_var])["result"][0][fallback_var]


def parse_args():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--device", default="192.168.0.254", help="IRF address (default: %(default)s)")
    p.add_argument("--user", default="admin", help="IRF user (default: %(default)s)")
    p.add_argument("--password", help="IRF password (asked for if omitted)")
    p.add_argument("--interface", help="Linux interface name to forward from (default: the "
                   "interface that holds --device, else the IRF WAN interface)")
    p.add_argument("--docker-ip", default="10.0.3.100",
                   help="address of the Docker namespace, pinned via Docker DHCP (default: %(default)s)")
    p.add_argument("--no-save", action="store_true", help="apply the settings, but do not save them")
    p.add_argument("--netbios", action="store_true", help="also forward tcp/139 (XP simulator)")
    return p.parse_args()


def main():
    args = parse_args()
    password = args.password or getpass.getpass(f"Password for {args.user}@{args.device}: ")
    dev = jsonrpcdevice.AdstecJSONRPCDevice(args.device, args.user, password)
    ifname = args.interface or default_interface(dev, args.device, "wan_ifname")
    ports = PORTS + ([NETBIOS] if args.netbios else [])

    # Settings, then delete the rules of this sample and verify it. Deleting
    # and inserting in the same session is not reliable on the IRF (row ids
    # and positions shift), so deletes and inserts use separate sessions.
    cfg = dev.sess_start()
    settings = {
        "docker_status": "enabled",
        "dhcp_startip_docker": args.docker_ip,
        "dhcp_endip_docker": args.docker_ip,
    }
    dev.config_set(cfg, settings)
    dev.sess_commit(cfg)
    own_comments = {comment(p, s) for p, _, s in ALL_PORTS}
    for _ in range(5):
        existing = dev.call("config", "table_get", tablename="forwarding", condition={})["forwarding"]
        own = [r for r in existing if r["fwcomment"] in own_comments]
        if not own:
            break
        cfg = dev.sess_start()
        for r in own:
            dev.table_del("forwarding", cfg, condition={"rowid": r["rowid"]})
        dev.sess_commit(cfg)
    else:
        sys.exit("ERROR: could not remove the existing rules of this sample")

    # Append the rules after the last rule in use
    existing = dev.call("config", "table_get", tablename="forwarding", condition={})["forwarding"]
    positions = [int(r["fwposition"]) for r in existing if str(r.get("fwposition", "")).isdigit()]
    first = max(positions, default=0) + 1
    cfg = dev.sess_start()
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

    # Verify that every rule of this sample exists
    rules = dev.call("config", "table_get", tablename="forwarding", condition={})["forwarding"]
    counts = {}
    for r in rules:
        counts[r["fwcomment"]] = counts.get(r["fwcomment"], 0) + 1
    wrong = [f"{comment(p, s)} ({counts.get(comment(p, s), 0)}x)" for p, _, s in ports if counts.get(comment(p, s), 0) != 1]
    if wrong:
        sys.exit("ERROR: forwarding rules not as expected after commit: " + ", ".join(wrong))
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
