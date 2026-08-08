#!/usr/bin/env bash
# Health check for the 802.1X bypass and its restore mechanism.
# Read-only. Run after deploy, after a reboot, and after a firmware upgrade.
#
# Usage:  scripts/verify.sh [ssh-host]     (default host: udm)

set -uo pipefail
HOST="${1:-udm}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Derive the expected boot scripts from the repo rather than hardcoding names.
# Hardcoding drifted the moment 10-wpa-supplicant.sh was renamed to 06-.
EXPECTED_SCRIPTS="$(cd "$REPO/on_boot.d" && ls -1 *.sh | tr '\n' ' ')"

ssh "$HOST" "EXPECTED_SCRIPTS='$EXPECTED_SCRIPTS' bash -s" <<'REMOTE' 2>&1 | grep -v "post-quantum\|store now\|openssh.com/pq"
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

echo
[ "$fail" -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
REMOTE
