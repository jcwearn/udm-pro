#!/usr/bin/env bash
# Health check for the 802.1X bypass, its restore mechanism, encrypted DNS,
# and Tailscale.
# Read-only. Run after deploy, after a reboot, and after a firmware upgrade.
#
# Usage:  scripts/verify.sh [ssh-host]     (default host: udm)

set -uo pipefail
HOST="${1:-udm}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Derive the expected boot scripts from the repo rather than hardcoding names.
# Hardcoding drifted the moment 10-wpa-supplicant.sh was renamed to 06-.
EXPECTED_SCRIPTS="$(cd "$REPO/on_boot.d" && ls -1 *.sh | tr '\n' ' ')"

# Likewise the pinned Tailscale version is whatever tarball packages/ holds.
TS_VERSION="$(basename "$REPO"/packages/tailscale_*_arm64.tgz)"
TS_VERSION="${TS_VERSION#tailscale_}"
TS_VERSION="${TS_VERSION%_arm64.tgz}"

ssh "$HOST" "EXPECTED_SCRIPTS='$EXPECTED_SCRIPTS' TS_VERSION='$TS_VERSION' bash -s" <<'REMOTE' 2>&1 | grep -v "post-quantum\|store now\|openssh.com/pq"
fail=0
ok()   { printf '  \033[32mOK  \033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

echo "== supplicant =="
if systemctl is-active --quiet wpa_supplicant.service; then
  ok "wpa_supplicant.service active"
else
  bad "wpa_supplicant.service NOT active"
fi

# The service can be active while authenticating nothing if the drop-in is
# missing, so assert on the actual command line, not just the unit state.
if tr '\0' ' ' < /proc/"$(systemctl show -p MainPID --value wpa_supplicant.service)"/cmdline 2>/dev/null | grep -q -- '-Dwired'; then
  ok "running with -Dwired (drop-in applied)"
else
  bad "NOT running with -Dwired — drop-in missing, auth is not happening"
fi

echo "== WAN =="
addr=$(ip -4 -o addr show eth8 2>/dev/null | awk '{print $4}' | head -1)
if [ -n "$addr" ]; then ok "eth8 has $addr"; else bad "eth8 has no IPv4"; fi
if ip route get 1.1.1.1 >/dev/null 2>&1; then ok "route to 1.1.1.1 exists"; else bad "no route to 1.1.1.1"; fi
if ping -c2 -W3 -I eth8 1.1.1.1 >/dev/null 2>&1; then ok "WAN carries traffic"; else bad "WAN ping failed"; fi

echo "== persistence mechanism =="
if systemctl is-enabled --quiet unifi-on-boot 2>/dev/null; then
  ok "unifi-on-boot enabled"
else
  bad "unifi-on-boot NOT enabled — nothing will restore after an upgrade"
fi
for s in ${EXPECTED_SCRIPTS:-}; do
  f="/data/on_boot.d/$s"
  [ -x "$f" ] && ok "$f present and executable" || bad "$f missing or not executable"
done

# Surface stale scripts left behind by a rename. They would still execute.
for f in /data/on_boot.d/*.sh; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  case " ${EXPECTED_SCRIPTS:-} " in
    *" $b "*) continue ;;
    *) echo "  WARN  $b is present but not in the repo — stale after a rename?" ;;
  esac
done

echo "== /data payload =="
for f in /data/wpa_supplicant/conf/wpa_supplicant.conf \
         /data/wpa_supplicant/systemd/override.conf \
         /data/ssh/authorized_keys; do
  [ -f "$f" ] && ok "$f" || bad "$f missing"
done
ls /data/wpa_supplicant/packages/wpasupplicant_*.deb >/dev/null 2>&1 \
  && ok "cached wpasupplicant .deb present" || bad "cached wpasupplicant .deb MISSING"
ls /data/wpa_supplicant/packages/libpcsclite1_*.deb >/dev/null 2>&1 \
  && ok "cached libpcsclite1 .deb present" || bad "cached libpcsclite1 .deb MISSING"

echo "== offline-install viability =="
# libssl1.1 is the tripwire: bullseye-only, removed in bookworm. If UniFi OS
# rebases, the cached bullseye .deb stops installing and the self-heal breaks.
. /etc/os-release
if [ "${VERSION_CODENAME:-}" = "bullseye" ]; then
  ok "base is bullseye — cached .deb matches"
else
  bad "base is ${VERSION_CODENAME:-unknown}, NOT bullseye — refresh packages/ before trusting the cache"
fi
dpkg-query -W -f='${Status}' libssl1.1 2>/dev/null | grep -q "install ok installed" \
  && ok "libssl1.1 present" || bad "libssl1.1 MISSING — wpasupplicant cannot install offline"

echo "== encrypted DNS =="
# The gateway will happily run the resolver while the controller has no record
# of it. That is how this reverted once already: the config key and the listener
# were both fine for two days, then the next reconcile deleted the service.
# So assert on the controller's record first — it is the one that decides.
doh=$(mongo --quiet --port 27117 ace --eval \
  'var d=db.setting.findOne({key:"doh"});print(d ? d.state+" "+(d.custom_servers||[]).length : "missing 0")' 2>/dev/null)
doh_state="${doh%% *}"
doh_count="${doh##* }"
if [ "$doh_state" = "on" ] && [ "${doh_count:-0}" -gt 0 ] 2>/dev/null; then
  ok "doh committed in controller (state=on, $doh_count custom server(s))"
else
  bad "doh NOT committed in controller (${doh:-unreadable}) — next re-provision will delete it"
fi

if python3 -c 'import json,sys;sys.exit("dohProxy" not in json.load(open("/data/udapi-config/udapi-net-cfg.json"))["services"])' 2>/dev/null; then
  ok "services.dohProxy present in gateway config"
else
  bad "services.dohProxy absent from gateway config"
fi

if ss -lnu 2>/dev/null | grep -q '127.0.0.1:5053'; then
  ok "dnscrypt-proxy listening on 127.0.0.1:5053"
else
  bad "nothing listening on 127.0.0.1:5053 — encrypted DNS is not resolving"
fi

echo "== tailscale =="
TS=/data/tailscale/bin/tailscale
have=$("$TS" version 2>/dev/null | head -1)
if [ "$have" = "${TS_VERSION:-}" ]; then
  ok "tailscale ${have} in /data/tailscale/bin (pinned)"
else
  bad "tailscale is ${have:-missing}, repo pins ${TS_VERSION:-?}"
fi
ls /data/tailscale/tailscale_*_arm64.tgz >/dev/null 2>&1 \
  && ok "staged tarball present" || bad "staged tarball MISSING — a firmware rebuild cannot reinstall"
[ -f /data/tailscale/tailscaled.service ] && ok "/data/tailscale/tailscaled.service" || bad "/data/tailscale/tailscaled.service missing"
if systemctl is-enabled --quiet tailscaled.service 2>/dev/null; then
  ok "tailscaled.service enabled"
else
  bad "tailscaled.service NOT enabled"
fi
if systemctl is-active --quiet tailscaled.service; then
  ok "tailscaled.service active"
else
  bad "tailscaled.service NOT active"
fi
# The state file is the node identity. It is what makes a firmware rebuild
# rejoin without a new auth key, and it lives here precisely so /etc can go.
[ -f /data/tailscale/tailscaled.state ] && ok "node identity in /data/tailscale/tailscaled.state" \
  || bad "no /data/tailscale/tailscaled.state — never joined, or state was moved"

# Everything from here reads the daemon. Prefs come from `tailscale debug
# prefs` (the local ipn.Prefs as JSON), status from `tailscale status --json`.
status=$("$TS" status --json 2>/dev/null)
prefs=$("$TS" debug prefs 2>/dev/null)
backend=$(printf '%s' "$status" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null)
if [ "$backend" = "Running" ]; then
  dnsname=$(printf '%s' "$status" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null)
  ok "BackendState Running (${dnsname:-no MagicDNS name})"
else
  bad "BackendState is '${backend:-unreadable}', not Running — 07-tailscale.sh prints the join command"
fi

# Nothing but the node itself: no DNS override, no routes in or out, no SSH
# server. --accept-dns=false is the one that matters — the UDM is the LAN's
# resolver and Tailscale must never rewrite /etc/resolv.conf.
pref() { printf '%s' "$prefs" | python3 -c "import json,sys;p=json.load(sys.stdin);print($1)" 2>/dev/null; }
if [ -z "$prefs" ]; then
  bad "cannot read prefs from tailscaled — daemon down?"
else
  [ "$(pref 'p.get("CorpDNS")')" = "False" ] \
    && ok "accept-dns off (CorpDNS=false)" || bad "accept-dns is ON — rejoin with --accept-dns=false"
  [ "$(pref 'p.get("RouteAll")')" = "False" ] \
    && ok "accept-routes off" || bad "accept-routes is ON"
  # An exit node is advertised as 0.0.0.0/0 and ::/0 in AdvertiseRoutes, so an
  # empty list rules out both subnet routes and exit-node advertisement.
  [ "$(pref 'len(p.get("AdvertiseRoutes") or [])')" = "0" ] \
    && ok "no routes advertised" || bad "routes advertised: $(pref 'p.get("AdvertiseRoutes")')"
  [ -z "$(pref 'p.get("ExitNodeID") or p.get("ExitNodeIP") or ""')" ] \
    && ok "no exit node in use" || bad "an exit node is in use"
  [ "$(pref 'p.get("RunSSH")')" = "False" ] \
    && ok "tailscale ssh off" || bad "tailscale ssh is ON"
  [ "$(pref 'p.get("Hostname")')" = "router" ] \
    && ok "hostname router" || bad "hostname is '$(pref 'p.get("Hostname")')', not router"
fi

if grep -q '100\.100\.100\.100' /etc/resolv.conf 2>/dev/null; then
  bad "/etc/resolv.conf points at 100.100.100.100 — Tailscale rewrote the router's DNS"
else
  ok "/etc/resolv.conf untouched by Tailscale"
fi
ip link show tailscale0 >/dev/null 2>&1 && ok "tailscale0 interface exists (kernel TUN)" \
  || bad "no tailscale0 interface — TUN unavailable or daemon not up"
# tailscaled defaults to iptables and hooks its own chains at the top of
# INPUT/FORWARD; UniFi's rules live below them. Absence means it chose
# nftables or netfilter is off, which is worth knowing but not a failure.
if iptables -S INPUT 2>/dev/null | grep -q -- '-j ts-input'; then
  ok "ts-input/ts-forward hooked into iptables ahead of UniFi's chains"
else
  echo "  WARN  no ts-input chain in iptables INPUT — check 'journalctl -u tailscaled' for the netfilter mode"
fi

echo
[ "$fail" -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
REMOTE
