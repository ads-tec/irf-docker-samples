/*
 * rpcapcat - capture from a remote rpcapd and write pcap to stdout.
 *
 * Copyright (c) 2026, ads-tec Industrial IT GmbH
 * SPDX-License-Identifier: BSD-2-Clause
 *
 *   rpcapcat -l                       list the interfaces of the rpcapd
 *   rpcapcat [-f filter] <iface>      capture, pcap on stdout
 *
 * Wireshark's dumpcap only opens rpcap:// sources when it was built against
 * a libpcap with remote support (HAVE_PCAP_REMOTE); Alpine's is not. This
 * tool uses pcap_open() directly, so:
 *   - the capture filter is compiled here and runs on the rpcapd, only
 *     matching packets cross the network
 *   - PCAP_OPENFLAG_NOCAPTURE_RPCAP keeps the rpcap data stream itself out
 *     of the capture (relevant when capturing the Docker interface)
 * Null authentication only (the IRF runs rpcapd -n).
 */
#include <errno.h>
#include <getopt.h>
#include <pcap/pcap.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pcap_t *handle;

/* KEY=value from the file the entrypoint writes; docker exec and ssh do not
 * carry the entrypoint's environment */
static const char *env_file_value(const char *key)
{
	static char values[2][256];
	static int used;
	char line[512];
	size_t klen = strlen(key);
	FILE *f = fopen("/etc/capture.env", "r");
	const char *found = NULL;

	if (!f)
		return NULL;
	while (!found && used < 2 && fgets(line, sizeof(line), f)) {
		if (strncmp(line, key, klen) == 0 && line[klen] == '=') {
			line[strcspn(line, "\r\n")] = '\0';
			snprintf(values[used], sizeof(values[used]), "%s", line + klen + 1);
			found = values[used++];
		}
	}
	fclose(f);
	return found;
}

static const char *setting(const char *key)
{
	const char *v = getenv(key);

	return v && *v ? v : env_file_value(key);
}
static int write_failed;

static void on_signal(int sig)
{
	(void)sig;
	if (handle)
		pcap_breakloop(handle);
}

static void on_packet(u_char *user, const struct pcap_pkthdr *h, const u_char *bytes)
{
	pcap_dumper_t *d = (pcap_dumper_t *)user;

	pcap_dump(user, h, bytes);
	/* flush per packet: the reader (tshark, Wireshark over ssh) is live */
	if (pcap_dump_flush(d) != 0) {
		write_failed = 1;
		pcap_breakloop(handle);
	}
}

static void usage(void)
{
	fprintf(stderr,
		"usage: rpcapcat [-H host] [-P port] -l\n"
		"       rpcapcat [-H host] [-P port] [-s snaplen] [-p] [-f filter] [-c count] <iface>\n"
		"  -H  rpcapd address (default: $RPCAP_HOST, /etc/capture.env)\n"
		"  -P  rpcapd port (default: $RPCAP_PORT, /etc/capture.env, 2002)\n"
		"  -l  list interfaces\n"
		"  -s  snapshot length (default 262144)\n"
		"  -p  no promiscuous mode\n"
		"  -f  capture filter (BPF), applied on the rpcapd\n"
		"  -c  stop after count packets\n");
	exit(2);
}

static int list_interfaces(const char *src)
{
	char errbuf[PCAP_ERRBUF_SIZE];
	pcap_if_t *all, *d;
	const char *prefix_end;

	if (pcap_findalldevs_ex(src, NULL, &all, errbuf) == -1) {
		fprintf(stderr, "rpcapcat: %s\n", errbuf);
		return 1;
	}
	/* names come back as rpcap://host:port/<iface>; print only <iface> */
	for (d = all; d; d = d->next) {
		prefix_end = strncmp(d->name, src, strlen(src)) == 0 ? d->name + strlen(src) : d->name;
		printf("%-16s %s\n", prefix_end, (d->flags & PCAP_IF_UP) ? "up" : "down");
	}
	pcap_freealldevs(all);
	return 0;
}

int main(int argc, char **argv)
{
	const char *host = setting("RPCAP_HOST");
	const char *port = setting("RPCAP_PORT");
	const char *filter = NULL;
	int snaplen = 262144, flags = PCAP_OPENFLAG_PROMISCUOUS | PCAP_OPENFLAG_NOCAPTURE_RPCAP;
	int list = 0, count = -1, c, rc;
	char src[PCAP_BUF_SIZE], errbuf[PCAP_ERRBUF_SIZE];
	struct bpf_program prog;
	struct sigaction sa;
	pcap_dumper_t *dumper;
	struct pcap_stat st;

	while ((c = getopt(argc, argv, "H:P:ls:pf:c:h")) != -1) {
		switch (c) {
		case 'H': host = optarg; break;
		case 'P': port = optarg; break;
		case 'l': list = 1; break;
		case 's': snaplen = atoi(optarg); break;
		case 'p': flags &= ~PCAP_OPENFLAG_PROMISCUOUS; break;
		case 'f': filter = optarg; break;
		case 'c': count = atoi(optarg); break;
		default: usage();
		}
	}
	if (!host || !*host) {
		fprintf(stderr, "rpcapcat: no rpcapd address (-H or RPCAP_HOST)\n");
		return 2;
	}
	if (!port || !*port)
		port = "2002";

	if (list) {
		snprintf(src, sizeof(src), "rpcap://%s:%s/", host, port);
		return list_interfaces(src);
	}
	if (optind != argc - 1)
		usage();
	snprintf(src, sizeof(src), "rpcap://%s:%s/%s", host, port, argv[optind]);

	handle = pcap_open(src, snaplen, flags, 100, NULL, errbuf);
	if (!handle) {
		fprintf(stderr, "rpcapcat: %s\n", errbuf);
		return 1;
	}
	/* Always install a filter, an empty one accepts everything: libpcap
	 * 1.10.7 fails to start a remote capture with NOCAPTURE_RPCAP and no
	 * filter ("Message payload is too short"). */
	if (pcap_compile(handle, &prog, filter ? filter : "", 1, PCAP_NETMASK_UNKNOWN) == -1 ||
	    pcap_setfilter(handle, &prog) == -1) {
		fprintf(stderr, "rpcapcat: filter: %s\n", pcap_geterr(handle));
		pcap_close(handle);
		return 1;
	}
	pcap_freecode(&prog);

	dumper = pcap_dump_fopen(handle, stdout);
	if (!dumper) {
		fprintf(stderr, "rpcapcat: %s\n", pcap_geterr(handle));
		pcap_close(handle);
		return 1;
	}
	if (pcap_dump_flush(dumper) != 0)
		write_failed = 1;

	/* stop cleanly on Ctrl-C / docker stop / closed pipe, so the rpcapd
	 * ends the remote capture */
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	rc = write_failed ? -2 : pcap_loop(handle, count, on_packet, (u_char *)dumper);
	if (rc == -1)
		fprintf(stderr, "rpcapcat: %s\n", pcap_geterr(handle));
	if (pcap_stats(handle, &st) == 0)
		fprintf(stderr, "rpcapcat: %u packets received, %u dropped\n", st.ps_recv, st.ps_drop);
	pcap_dump_close(dumper);
	pcap_close(handle);
	return rc == -1 ? 1 : 0;
}
