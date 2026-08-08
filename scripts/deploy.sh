#!/usr/bin/env bash
# Push everything the UDM needs to self-heal into /data, then install the
# on_boot.d scripts. Safe to re-run; it converges rather than toggles.
#
# Usage:  scripts/deploy.sh [ssh-host]     (default host: udm)

set -euo pipefail

HOST="${1:-udm}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGE_KEY="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/router.txt}"

[ -f "$AGE_KEY" ] || { echo "ERROR: age key not found at $AGE_KEY" >&2; exit 1; }
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
ssh "$HOST" 'install -d -m 0755 /data/wpa_supplicant/conf /data/wpa_supplicant/packages /data/wpa_supplicant/systemd /data/ssh /data/on_boot.d'

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

# Boot scripts
scp -q "$REPO"/on_boot.d/*.sh "$HOST:/data/on_boot.d/"
ssh "$HOST" 'chmod 755 /data/on_boot.d/*.sh'

echo "==> staged. contents:"
ssh "$HOST" 'find /data/wpa_supplicant /data/ssh /data/on_boot.d -type f | sort'

echo
echo "Done. Run scripts/verify.sh to confirm health, or"
echo "  ssh $HOST systemctl restart unifi-on-boot"
echo "to exercise the restore path without rebooting."
