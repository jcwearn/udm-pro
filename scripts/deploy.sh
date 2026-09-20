#!/usr/bin/env bash
# Push everything the UDM needs to self-heal into /data, then install the
# on_boot.d scripts. Safe to re-run; it converges rather than toggles.
#
# Usage:  scripts/deploy.sh [ssh-host]     (default host: udm)

set -euo pipefail

HOST="${1:-udm}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# This repo has its own age identity, deliberately separate from any other.
# Do NOT inherit an ambient SOPS_AGE_KEY_FILE: a global one set by the shell
# profile points at a different identity and produces a confusing
# "no identity matched any of the recipients" failure. Override with
# UDM_AGE_KEY_FILE if the key genuinely lives elsewhere.
AGE_KEY="${UDM_AGE_KEY_FILE:-$HOME/.config/sops/age/router.txt}"

[ -f "$AGE_KEY" ] || {
  echo "ERROR: age key not found at $AGE_KEY" >&2
  echo "       Restore it from your password manager, or set UDM_AGE_KEY_FILE." >&2
  exit 1
}

# Fail early and legibly if the key cannot open these files, rather than
# midway through decryption.
RECIPIENT="$(grep -o 'age1[a-z0-9]*' "$REPO/.sops.yaml" | head -1)"
if ! grep -q "public key: ${RECIPIENT}" "$AGE_KEY"; then
  echo "ERROR: $AGE_KEY does not hold the identity for $RECIPIENT" >&2
  echo "       That key cannot decrypt secrets/ in this repo." >&2
  exit 1
fi
export SOPS_AGE_KEY_FILE="$AGE_KEY"

# Decrypt into a private temp dir that is removed on any exit path, including
# failure and interrupt. Plaintext key material must never outlive this script.
STAGE="$(mktemp -d)"
chmod 700 "$STAGE"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT INT TERM

echo "==> decrypting secrets"
mkdir -p "$STAGE/conf"
for f in "$REPO"/secrets/*.sops; do
  out="$STAGE/conf/$(basename "${f%.sops}")"
  sops -d --input-type binary --output-type binary "$f" > "$out"
  chmod 640 "$out"
  echo "    $(basename "$out")"
done

echo "==> staging /data on $HOST"
ssh "$HOST" 'install -d -m 0755 /data/wpa_supplicant/conf /data/wpa_supplicant/packages /data/wpa_supplicant/systemd /data/ssh /data/tailscale /data/on_boot.d'

# Certs + conf
scp -q "$STAGE"/conf/* "$HOST:/data/wpa_supplicant/conf/"
ssh "$HOST" 'chmod 640 /data/wpa_supplicant/conf/*'

# Cached packages. unifi-on-boot keeps its own copy in /data/unifi-on-boot,
# so only the supplicant's packages belong here.
scp -q "$REPO"/packages/wpasupplicant_*.deb "$REPO"/packages/libpcsclite1_*.deb \
       "$HOST:/data/wpa_supplicant/packages/"

# systemd drop-in
scp -q "$REPO"/systemd/wpa_supplicant.service.d/override.conf \
       "$HOST:/data/wpa_supplicant/systemd/override.conf"

# authorized_keys
scp -q "$REPO"/ssh/udm_ed25519.pub "$HOST:/data/ssh/authorized_keys"
ssh "$HOST" 'chmod 600 /data/ssh/authorized_keys'

# Tailscale: the pinned tarball, its hash, and the unit file. 07-tailscale.sh
# reads the version from the tarball's filename, so exactly one may be staged;
# anything else there (tailscaled.state, bin/) is the box's and is left alone.
# The tarball is 34 MB, so it is only sent when the box does not already hold
# a matching copy.
tarball="$(basename "$REPO"/packages/tailscale_*_arm64.tgz)"
tarball_sum="$(grep " ${tarball}\$" "$REPO/packages/SHA256SUMS" | cut -d' ' -f1 || true)"
[ -n "$tarball_sum" ] || { echo "ERROR: ${tarball} has no entry in packages/SHA256SUMS" >&2; exit 1; }
printf '%s  %s\n' "$tarball_sum" "$REPO/packages/${tarball}" | shasum -a 256 -c --status || {
  echo "ERROR: packages/${tarball} does not match packages/SHA256SUMS" >&2; exit 1; }
if ! printf '%s  /data/tailscale/%s\n' "$tarball_sum" "$tarball" | ssh "$HOST" 'sha256sum -c --status'; then
  echo "    sending ${tarball}"
  scp -q "$REPO/packages/${tarball}" "$HOST:/data/tailscale/${tarball}"
fi
printf '%s\n' "$tarball" | ssh "$HOST" 'keep=$(cat); find /data/tailscale -maxdepth 1 -name "tailscale_*_arm64.tgz" ! -name "$keep" -delete'
scp -q "$REPO"/packages/SHA256SUMS "$HOST:/data/tailscale/SHA256SUMS"
scp -q "$REPO"/systemd/tailscaled.service "$HOST:/data/tailscale/tailscaled.service"

# The box once ran the community tailscale-udm package, which also used
# /data/tailscale. Its manage.sh and tailscale-env are inert under this
# layout, but say so rather than leave the captain wondering which one is live.
ssh "$HOST" 'for f in /data/tailscale/manage.sh /data/tailscale/tailscale-env; do
  [ -e "$f" ] && echo "    WARN  $f is a tailscale-udm leftover; 07-tailscale.sh does not use it"
done; true'

# Boot scripts
scp -q "$REPO"/on_boot.d/*.sh "$HOST:/data/on_boot.d/"
ssh "$HOST" 'chmod 755 /data/on_boot.d/*.sh'

echo "==> staged. contents:"
ssh "$HOST" 'find /data/wpa_supplicant /data/ssh /data/tailscale /data/on_boot.d -type f | sort'

echo
echo "Done. Run scripts/verify.sh to confirm health, or"
echo "  ssh $HOST systemctl restart unifi-on-boot"
echo "to exercise the restore path without rebooting."
echo "First Tailscale deploy: 07-tailscale.sh prints the one-time join command;"
echo "  see README, Tailscale."
