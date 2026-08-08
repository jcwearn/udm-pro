#!/bin/bash
# Restore root's authorized_keys after a firmware rebuild.
#
# /root/.ssh lives in the root filesystem, which UniFi OS upgrades replace.
# Without this, key auth breaks on exactly the upgrade this repo exists to
# survive, and you fall back to the console password.
#
# Runs before 10-wpa-supplicant.sh so that if the supplicant restore fails
# you still have key-based access to debug it.

set -u

SRC=/data/ssh/authorized_keys
DEST=/root/.ssh/authorized_keys

[ -f "$SRC" ] || { echo "05-ssh-keys: no $SRC, nothing to restore"; exit 0; }

install -d -m 0700 /root/.ssh
touch "$DEST"
chmod 600 "$DEST"

# Append only keys that are missing. Never overwrite: a key added out of band
# (UI, ssh-copy-id) must not be silently dropped by this script.
added=0
while IFS= read -r key; do
  [ -n "$key" ] || continue
  case "$key" in \#*) continue ;; esac
  if ! grep -qxF "$key" "$DEST"; then
    printf '%s\n' "$key" >> "$DEST"
    added=$((added + 1))
  fi
done < "$SRC"

echo "05-ssh-keys: restored ${added} key(s) to ${DEST}"
