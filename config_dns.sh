#!/system/bin/sh
# shellcheck shell=ash
# config_dns.sh — the DNS enforcer's settings: poll interval, log and iptables
# chain names, the trusted DoT host, and the DoH endpoint lists that
# dns_iptables.sh turns into reject rules.
#
# Sourced by config.sh where these definitions used to sit.
#
# Nothing python_pkg/focus_policy/loader.py reads may move into a sibling: it
# regex-scans the text of config.sh ALONE, so a name moved out becomes an
# empty value with no error at all. See the pinned list in config_paths.sh.

# --- DNS enforcer state (see dns_enforcer.sh) ---
# The hosts file is only consulted by the *system* resolver. Apps using
# DNS-over-HTTPS (DoH, e.g. Chrome's built-in secure DNS) or DNS-over-TLS
# (DoT, e.g. Android 9+ Private DNS "opportunistic" mode) bypass it.
# The DNS enforcer pins Private DNS to OFF and blocks well-known DoH/DoT
# endpoints so lookups fall back to the system resolver -> hosts file.
export DNS_CHECK_INTERVAL=20
export DNS_LOG="$STATE_DIR/dns_enforcer.log"
# --- Trusted DoT resolver (opt-in, empty = old behaviour) ---
# Set this to the hostname of a DoT resolver you control, and the enforcer
# switches from "no DoT at all" to "only YOUR DoT". Two things change:
#   1. an ACCEPT for that resolver's IPs is inserted BEFORE the blanket
#      853 REJECT, so the connection survives;
#   2. private_dns_mode is pinned to "hostname" with this specifier, instead
#      of being forced off -- so the phone cannot silently fall back to a
#      resolver that does not filter.
# Leave EMPTY to keep the original behaviour (Private DNS forced off, all
# 853 rejected). Do not point this at a public resolver: the whole point is
# that the resolver applies your blocklist. See python_pkg/focus_policy.
export DNS_TRUSTED_DOT_HOST=""
# Where to resolve DNS_TRUSTED_DOT_HOST when Private DNS is pinned to it.
# Chicken-and-egg: the resolver's own name must resolve without using it.
# Space-separated IPv4/IPv6 literals; leave empty to resolve at runtime.
export DNS_TRUSTED_DOT_IPS=""
# iptables chain used exclusively by us; we flush+refill it every check.
export DNS_IPT_CHAIN="FOCUS_DNS_BLOCK"
# DoH/DoT endpoints to DROP. Well-known public resolvers used by browsers
# and OS when Private DNS is enabled. Updating this list is cheap — just
# edit and redeploy.
export DNS_DOH_HOSTS="
dns.google
dns64.dns.google
dns.quad9.net
dns.cloudflare.com
one.one.one.one
cloudflare-dns.com
mozilla.cloudflare-dns.com
chrome.cloudflare-dns.com
dns.nextdns.io
doh.opendns.com
dns.adguard-dns.com
dns.adguard.com
dns.controld.com
"
# IPv4/IPv6 literals used by DoT (port 853) and DoH (port 443). Anything
# not already resolved via /etc/hosts still needs literal-IP blocks.
export DNS_DOH_IPV4="
8.8.8.8
8.8.4.4
1.1.1.1
1.0.0.1
9.9.9.9
149.112.112.112
94.140.14.14
94.140.15.15
208.67.222.222
208.67.220.220
45.90.28.0
45.90.30.0
104.16.248.249
104.16.249.249
"
export DNS_DOH_IPV6="
2001:4860:4860::8888
2001:4860:4860::8844
2606:4700:4700::1111
2606:4700:4700::1001
2620:fe::fe
2620:fe::9
2a10:50c0::ad1:ff
2a10:50c0::ad2:ff
2606:4700::6810:f8f9
2606:4700::6810:f9f9
"
