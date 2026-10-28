#!/usr/bin/env python3
# Copyright (c) 2026, ads-tec Industrial IT GmbH
# SPDX-License-Identifier: BSD-2-Clause
"""Configure an ADS-TEC IRF3000 for the packet capture sample.

Enables Docker, pins the Docker DHCP pool to a single address, enables the
IRF's remote capture server (rpcapd) for that address only and reachable only
on the Docker interface, and forwards the SSH port of the container from the
LAN interface. On firmware 3.0 (INPUT default-deny) it also checks that the
INPUT allow table opens tcp/2002 and tcp/2003 on the Docker interface only.

Requires the ads-tec JSON-RPC client library (jsonrpcdevice.py) and requests:
    https://github.com/ads-tec/Python-AdstecJSONRPCDevice
    pip install requests

Settings changed through the JSON-RPC API are only applied until the next
reboot unless they are saved; this script saves them at the end (--no-save
skips that).

Examples:
    python3 setup_rpcap.py --device 192.168.0.254
    python3 setup_rpcap.py --device 192.168.0.254 --web
    python3 setup_rpcap.py --device 192.168.0.254 --disable
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

COMMENT_PREFIX = "Capture"

# rpcapd control and data port (rpcapd -p 2002 -t 2003)
RPCAP_PORTS = ("2002", "2003")

# (proto, port or range, service)
PORTS = [
    ("tcp", "2223", "SSH"),
]
# --web: webshark UI directly (container started with WEB_LISTEN=0.0.0.0:8085)
WEB_PORTS = [
    ("tcp", "8085", "WebShark"),
]
ALL_PORTS = PORTS + WEB_PORTS


def comment(proto, service):
    return f"{COMMENT_PREFIX} {service} {proto}"


def config_values(dev, names):
    res = dev.config_get(names)["result"]
    return {k: v for d in res for k, v in d.items()}


def default_interface(dev, address, fallback_var):
    """Linux interface that holds the given IRF address.

    In "IP router (extended)" mode the LAN address is on a port interface
    (e.g. lan_port1 = ETH2) and lan_ifname still names the unused bridge, so
    look up the symbolic interface whose IP address matches.
    """
    symbolic = dev.status("symbolic_ifnames_with_umts_with_ipsec").split()
    for name in symbolic:
        try:
            values = config_values(dev, [f"{name}_ipaddr", f"{name}_ifname"])
        except Exception:
            continue
        if values.get(f"{name}_ipaddr") == address and values.get(f"{name}_ifname"):
            return values[f"{name}_ifname"]
    return config_values(dev, [fallback_var])[fallback_var]


def table_rows(dev, table):
    """Rows of a configdb table, None if the firmware does not have it."""
    try:
        return dev.call("config", "table_get", tablename=table, condition={})[table]
    except Exception:
        return None


def interface_names(dev):
    """Native names of all configured interfaces.

    The symbolic interfaces, plus on firmware 3.0 the variables of
    input_allow_ifvars (the INPUT filter's interface universe, which also
    holds lan_port1..7 = ETH2.. in "IP router (extended)" mode).
    """
    variables = [f"{n}_ifname" for n in dev.status("symbolic_ifnames_with_umts_with_ipsec").split()]
    variables += [r["iai_var"] for r in table_rows(dev, "input_allow_ifvars") or []]
    names = set()
    for var in dict.fromkeys(variables):
        try:
            value = config_values(dev, [var]).get(var, "")
        except Exception:
            continue
        names.update(n for n in str(value).split() if n and len(n) <= 15)
    return names


def check_input_allow(dev, docker_ifname, enabled):
    """Firmware 3.0: INPUT is default-deny, the table input_allow opens ports.

    libnvram keeps input_allow in sync with rpcap_access (catalogue service
    rpcap_access = tcp/2002 + tcp/2003). Make sure the result is exactly
    "open on the Docker interface" (or nowhere when disabled): add missing
    rows, remove rows of other interfaces.
    """
    rows = table_rows(dev, "input_allow")
    if rows is None:
        return "no input_allow table (firmware < 3.0), rpcap_access only"
    rpcap = [r for r in rows if r["ia_proto"] == "tcp" and r["ia_port"] in RPCAP_PORTS]
    extra = [r for r in rpcap if not enabled or r["ia_ifname"] != docker_ifname]
    have = {r["ia_port"] for r in rpcap if r["ia_ifname"] == docker_ifname}
    missing = [p for p in RPCAP_PORTS if enabled and p not in have]
    if extra:
        cfg = dev.sess_start()
        for r in extra:
            dev.table_del("input_allow", cfg, condition={"rowid": r["rowid"]})
        dev.sess_commit(cfg)
    if missing:
        cfg = dev.sess_start()
        for port in missing:
            dev.table_insert("input_allow", cfg, [docker_ifname, "tcp", port])
        dev.sess_commit(cfg)
    rows = table_rows(dev, "input_allow")
    now = sorted(f"{r['ia_ifname']} tcp/{r['ia_port']}" for r in rows
                 if r["ia_proto"] == "tcp" and r["ia_port"] in RPCAP_PORTS)
    changes = []
    if extra:
        changes.append("removed " + ", ".join(f"{r['ia_ifname']} tcp/{r['ia_port']}" for r in extra))
    if missing:
        changes.append("added " + ", ".join(f"{docker_ifname} tcp/{p}" for p in missing))
    return "input_allow: " + (", ".join(now) or "none") + (f" ({'; '.join(changes)})" if changes else "")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--device", default="192.168.0.254", help="IRF address (default: %(default)s)")
    p.add_argument("--user", default="admin", help="IRF user (default: %(default)s)")
    p.add_argument("--password", help="IRF password (asked for if omitted)")
    p.add_argument("--interface", help="Linux interface name to forward from (default: the "
                   "interface that holds --device, else the IRF LAN interface)")
    p.add_argument("--docker-ip", default="10.0.3.100",
                   help="address of the Docker namespace, pinned via Docker DHCP (default: %(default)s)")
    p.add_argument("--web", action="store_true",
                   help="also forward tcp/8085 to the webshark UI (container with "
                   "WEB_LISTEN=0.0.0.0:8085, HTTP basic auth)")
    p.add_argument("--disable", action="store_true",
                   help="disable the remote capture server and remove the forwarding rules")
    p.add_argument("--no-save", action="store_true", help="apply the settings, but do not save them")
    return p.parse_args()


def delete_own_rules(dev):
    # Deleting and inserting in the same session is not reliable on the IRF
    # (row ids and positions shift), so deletes and inserts use separate
    # sessions.
    own_comments = {comment(p, s) for p, _, s in ALL_PORTS}
    for _ in range(5):
        existing = dev.call("config", "table_get", tablename="forwarding", condition={})["forwarding"]
        own = [r for r in existing if r["fwcomment"] in own_comments]
        if not own:
            return
        cfg = dev.sess_start()
        for r in own:
            dev.table_del("forwarding", cfg, condition={"rowid": r["rowid"]})
        dev.sess_commit(cfg)
    sys.exit("ERROR: could not remove the existing rules of this sample")


def save(dev, no_save):
    if not no_save:
        dev.config_set_commit({"save_now": "1"})
        print("Settings saved.")
    else:
        print("Settings applied, NOT saved - they are lost on the next reboot.")


def main():
    args = parse_args()
    password = args.password or getpass.getpass(f"Password for {args.user}@{args.device}: ")
    dev = jsonrpcdevice.AdstecJSONRPCDevice(args.device, args.user, password)

    docker_ifname = config_values(dev, ["docker_ifname"]).get("docker_ifname") or "lxcbr0"

    if args.disable:
        # deny on every interface: also closes the input_allow rows (3.0)
        dev.config_set_commit({"rpcap_status": "disabled",
                               "rpcap_access": " ".join(sorted(interface_names(dev)))})
        print(check_input_allow(dev, docker_ifname, enabled=False))
        delete_own_rules(dev)
        print("Remote capture disabled, forwarding rules removed.")
        save(dev, args.no_save)
        dev.logout()
        return

    ifname = args.interface or default_interface(dev, args.device, "lan_ifname")

    cfg = dev.sess_start()
    dev.config_set(cfg, {
        "docker_status": "enabled",
        "dhcp_startip_docker": args.docker_ip,
        "dhcp_endip_docker": args.docker_ip,
    })
    dev.sess_commit(cfg)

    docker_ipaddr = config_values(dev, ["docker_ipaddr"]).get("docker_ipaddr") or "?"
    # rpcap_access is a deny list: every interface except the Docker one
    blocked = " ".join(sorted(interface_names(dev) - {docker_ifname}))
    cfg = dev.sess_start()
    dev.config_set(cfg, {
        "rpcap_status": "enabled",
        "rpcap_hostlist": args.docker_ip,   # rpcapd -l: only the container may connect
        "rpcap_access": blocked,            # tcp/2002+2003 blocked except on Docker
    })
    dev.sess_commit(cfg)
    input_allow = check_input_allow(dev, docker_ifname, enabled=True)

    delete_own_rules(dev)
    # Append the rules after the last rule in use
    existing = dev.call("config", "table_get", tablename="forwarding", condition={})["forwarding"]
    positions = [int(r["fwposition"]) for r in existing if str(r.get("fwposition", "")).isdigit()]
    first = max(positions, default=0) + 1
    cfg = dev.sess_start()
    ports = PORTS + (WEB_PORTS if args.web else [])
    for position, (proto, port, service) in enumerate(ports, start=first):
        dev.table_insert("forwarding", cfg, [
            ifname,                  # fwifname
            proto,                   # fwproto
            "",                      # fwlocalip
            port,                    # fwlocalport
            args.docker_ip,          # fwtargetip
            port,                    # fwtargetport
            "enabled",               # fwsnat: the Docker namespace has no route back to the clients
            "",                      # fwsrcnet
            comment(proto, service), # fwcomment
            "enabled",               # fwenabled
            str(position),           # fwposition
            "disabled",              # fwrsnat
        ])
    dev.sess_commit(cfg)

    # Verify
    rules = dev.call("config", "table_get", tablename="forwarding", condition={})["forwarding"]
    counts = {}
    for r in rules:
        counts[r["fwcomment"]] = counts.get(r["fwcomment"], 0) + 1
    wrong = [f"{comment(p, s)} ({counts.get(comment(p, s), 0)}x)" for p, _, s in ports
             if counts.get(comment(p, s), 0) != 1]
    if wrong:
        sys.exit("ERROR: forwarding rules not as expected after commit: " + ", ".join(wrong))
    rpcap = config_values(dev, ["rpcap_status", "rpcap_hostlist", "rpcap_access"])

    print(f"Remote capture: {rpcap['rpcap_status']}, client {rpcap['rpcap_hostlist']}, "
          f"rpcapd at {docker_ipaddr}:2002 on {docker_ifname}")
    print(f"  blocked on: {rpcap['rpcap_access'] or '-'}")
    print(f"  {input_allow}")
    print(f"Forwarding rules on {ifname} -> {args.docker_ip}:")
    for r in rules:
        if r["fwcomment"].startswith(COMMENT_PREFIX + " "):
            print(f"  {r['fwproto']}/{r['fwlocalport']} -> {r['fwtargetip']}:{r['fwtargetport']}")
    print("The remote capture server sees all traffic of the IRF: disable it when not needed "
          "(--disable).")

    save(dev, args.no_save)
    dev.logout()


if __name__ == "__main__":
    main()
