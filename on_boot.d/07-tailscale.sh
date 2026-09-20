#!/bin/bash
# Restore Tailscale after a firmware rebuild.
#
# Everything with a lifetime lives in /data/tailscale: the staged tarball, the
# extracted binaries, the unit file, and — the part that matters — the node
# identity in tailscaled.state. A UniFi OS upgrade wipes /etc, /usr and /var, so
# what it costs is the unit file in /etc/systemd/system, and that is put back
# here. The node key survives in /data, so the router rejoins the tailnet on
# its own; no auth key is stored on the box or in the repo.
#
# The join itself is a one-time step done by hand (README, "Tailscale"). If the
# node has never joined, or was logged out on purpose, this prints the exact
# command and exits 0. It never runs `tailscale up` itself.
#
# Runs after 06-wpa-supplicant.sh: the tailnet needs WAN, WAN does not need the
# tailnet, and nothing here may delay 802.1X.
#
# On an ordinary reboot this is a no-op: every step is guarded.

set -u

DATA=/data/tailscale
UNIT=/etc/systemd/system/tailscaled.service
TS="${DATA}/bin/tailscale"
changed=0

# Derive the log prefix from the filename so it cannot drift out of sync with
# the script's ordering prefix.
log() { echo "$(basename "$0" .sh): $*"; }

# --- 1. Binaries ------------------------------------------------------------
# The pinned version is the staged tarball's filename; deploy.sh keeps exactly
# one there and the tarball's own line in the staged SHA256SUMS is checked
# before anything is extracted. Binaries are (re)installed only when missing
# or when `tailscale version` disagrees with the tarball, so a deploy that
# stages a newer tarball upgrades on the next boot (or the next unifi-on-boot
# restart).
set -- "${DATA}"/tailscale_*_arm64.tgz
tarball=$1
[ -f "$tarball" ] || { log "no tarball in ${DATA}, nothing to restore"; exit 0; }
want=$(basename "$tarball")
want=${want#tailscale_}
want=${want%_arm64.tgz}

have=$("$TS" version 2>/dev/null | head -1)
if [ "$have" != "$want" ]; then
  log "tailscale ${have:-missing}, want ${want} — installing from $(basename "$tarball")"
  sum=$(grep " $(basename "$tarball")\$" "${DATA}/SHA256SUMS" 2>/dev/null)
  if [ -z "$sum" ]; then
    log "ERROR: $(basename "$tarball") has no entry in ${DATA}/SHA256SUMS — not installing"
    exit 1
  fi
  if ! (cd "$DATA" && printf '%s\n' "$sum" | sha256sum -c --quiet --status); then
    log "ERROR: $(basename "$tarball") does not match ${DATA}/SHA256SUMS — not installing"
    exit 1
  fi
  tmp=$(mktemp -d "${DATA}/extract.XXXXXX")
  if tar -xzf "$tarball" -C "$tmp" --strip-components=1 \
       "tailscale_${want}_arm64/tailscale" "tailscale_${want}_arm64/tailscaled"; then
    # install(1) unlinks before writing, so replacing a running tailscaled
    # succeeds where cp would fail with "Text file busy".
    install -d -m 0755 "${DATA}/bin"
    install -m 0755 "$tmp/tailscale" "$tmp/tailscaled" "${DATA}/bin/"
    rm -rf "$tmp"
    log "installed tailscale $("$TS" version 2>/dev/null | head -1) to ${DATA}/bin"
    changed=1
  else
    rm -rf "$tmp"
    log "ERROR: could not extract $(basename "$tarball")"
    exit 1
  fi
fi

# --- 2. Unit file -----------------------------------------------------------
# Compare content rather than existence, as 06- does for its drop-in: a stale
# unit that still starts would be the silent failure.
if [ ! -f "$UNIT" ] || ! cmp -s "${DATA}/tailscaled.service" "$UNIT"; then
  install -m 0644 "${DATA}/tailscaled.service" "$UNIT"
  log "restored $(basename "$UNIT")"
  changed=1
fi

# --- 3. Enable and start ----------------------------------------------------
if [ "$changed" -eq 1 ]; then
  # A new unit or new binaries: reload so systemd sees the file as written,
  # then restart rather than start in case the old binary is still running.
  systemctl daemon-reload
  systemctl enable tailscaled.service >/dev/null 2>&1
  systemctl restart tailscaled.service
  log "restarted tailscaled.service after restore"
else
  systemctl enable tailscaled.service >/dev/null 2>&1
  systemctl is-active --quiet tailscaled.service || {
    systemctl start tailscaled.service
    log "started tailscaled.service"
  }
fi

# --- 4. Report --------------------------------------------------------------
# Poll rather than sleep: the daemon needs a moment to open its socket, and a
# node with a valid key needs a control-plane round trip before it reports
# Running. Anything other than Running is printed as what to do about it.
state=""
for _ in $(seq 1 30); do
  state=$("$TS" status --json 2>/dev/null \
    | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p' | head -1)
  case "$state" in
    Running|NeedsLogin|NeedsMachineAuth|Stopped) break ;;
  esac
  sleep 1
done

case "$state" in
  Running)
    log "joined; tailscale status:"
    "$TS" status
    ;;
  NeedsLogin|Stopped)
    if [ -f "${DATA}/tailscaled.state" ] && [ "$state" = "NeedsLogin" ]; then
      log "not joined (BackendState=${state}: no valid node key in ${DATA}/tailscaled.state)"
    else
      log "not joined (BackendState=${state})"
    fi
    log "join once, by hand — this script never does it:"
    log "  ${TS} up --accept-dns=false --accept-routes=false --advertise-routes= --ssh=false --hostname=router"
    log "  (append --auth-key=tskey-auth-... or follow the login URL it prints)"
    ;;
  NeedsMachineAuth)
    log "waiting for machine approval in the Tailscale admin console"
    ;;
  *)
    # Starting for 30s means no control-plane round trip completed: WAN down,
    # or the daemon is not answering on its socket at all (state empty).
    log "ERROR: tailscaled not Running after 30s (BackendState=${state:-none}) — see journalctl -u tailscaled"
    exit 1
    ;;
esac
