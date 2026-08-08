#!/bin/bash
# Restore the AT&T EAP-TLS 802.1X supplicant after a firmware rebuild.
#
# This replicates the configuration that is actually running on the box, which
# differs from the commonly-published UDM recipes in two ways worth knowing:
#
#   1. It uses the generic wpa_supplicant.service with an ExecStart override,
#      NOT wpa_supplicant-wired@eth8.service. The @-template unit exists and is
#      disabled; enabling it instead would start a second, differently
#      configured supplicant.
#   2. Certs live in /etc/wpa_supplicant/conf/, not /etc/wpa_supplicant/certs/,
#      and the conf references them by their full extraction-tool filenames.
#      The filenames are load-bearing — the conf hardcodes absolute paths.
#
# Everything it touches under /etc is wiped by a UniFi OS upgrade: the package,
# the certs, the conf, the drop-in, and the enable symlink. /data survives.
#
# On an ordinary reboot this is a no-op: every step is guarded.

set -u

DATA=/data/wpa_supplicant
IFACE=eth8
DROPIN=/etc/systemd/system/wpa_supplicant.service.d
changed=0

# Derive the log prefix from the filename so it cannot drift out of sync with
# the script's ordering prefix, as it did when this moved from 10- to 06-.
log() { echo "$(basename "$0" .sh): $*"; }

# --- 1. Package -------------------------------------------------------------
# Order is explicit: libpcsclite1 is a dependency of wpasupplicant, and
# installing them in the wrong order leaves dpkg in a half-configured state.
# The other nine dependencies ship with the UniFi OS base image; libssl1.1 is
# the fragile one (bullseye-only, gone in bookworm) — if UniFi OS ever rebases,
# this install fails and scripts/discover.sh will show it.
if ! command -v wpa_supplicant >/dev/null 2>&1; then
  log "wpa_supplicant missing — reinstalling from cached packages"
  dpkg -i "${DATA}"/packages/libpcsclite1_*.deb || log "WARNING: libpcsclite1 install failed"
  dpkg -i "${DATA}"/packages/wpasupplicant_*.deb || log "WARNING: wpasupplicant install failed"
  changed=1
fi

# --- 2. Certs and config ----------------------------------------------------
install -d -m 0755 /etc/wpa_supplicant/conf
for src in "${DATA}"/conf/*; do
  [ -f "$src" ] || continue
  dest="/etc/wpa_supplicant/conf/$(basename "$src")"
  if [ ! -f "$dest" ]; then
    install -m 0640 "$src" "$dest"
    log "restored $(basename "$src")"
    changed=1
  fi
done

# --- 3. systemd drop-in -----------------------------------------------------
# Without this the service starts with Debian's default dbus ExecStart, which
# has no -Dwired and no -ieth8, so it comes up "active" while authenticating
# nothing. A silent success is the worst failure mode here, so compare content
# rather than mere existence.
if [ ! -f "${DROPIN}/override.conf" ] || \
   ! cmp -s "${DATA}/systemd/override.conf" "${DROPIN}/override.conf"; then
  install -d -m 0755 "$DROPIN"
  install -m 0644 "${DATA}/systemd/override.conf" "${DROPIN}/override.conf"
  log "restored systemd override"
  changed=1
fi

# --- 4. Enable and start ----------------------------------------------------
systemctl enable wpa_supplicant.service >/dev/null 2>&1

if [ "$changed" -eq 1 ]; then
  # Something was restored. The service may already be running with the stock
  # ExecStart, so reload and restart rather than start.
  systemctl daemon-reload
  systemctl restart wpa_supplicant.service
  log "restarted wpa_supplicant.service after restore"
else
  systemctl is-active --quiet wpa_supplicant.service || {
    systemctl start wpa_supplicant.service
    log "started wpa_supplicant.service"
  }
fi

# --- 5. Report --------------------------------------------------------------
# Poll rather than sleeping a fixed interval. EAP auth and the DHCP lease that
# follows it do not complete instantly: a flat 3s check logged an empty address
# on a real post-wipe boot even though WAN came up fine seconds later, which
# reads like a failure in exactly the log you would be searching during one.
addr=""
for _ in $(seq 1 30); do
  addr=$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | head -1)
  [ -n "$addr" ] && break
  sleep 1
done

if systemctl is-active --quiet wpa_supplicant.service; then
  log "service active; ${IFACE} addr: ${addr:-<none yet>}"
else
  log "ERROR: wpa_supplicant.service is not active — WAN will be down"
fi
