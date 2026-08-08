#!/bin/bash
# Phase 1 pre-flight discovery — READ ONLY, changes nothing.
# Run: bash udm-discovery.sh > /tmp/udm-discovery.txt 2>&1

echo "===== 1. DEBIAN BASE (load-bearing) ====="
cat /etc/os-release

echo; echo "===== 2. DEVICE / FIRMWARE ====="
ubnt-device-info 2>/dev/null || echo "(ubnt-device-info not found)"

echo; echo "===== 3. WPA_SUPPLICANT BINARY ====="
command -v wpa_supplicant || echo "(not on PATH)"
ls -la /sbin/wpa_supplicant /usr/sbin/wpa_supplicant 2>/dev/null
wpa_supplicant -v 2>&1 | head -3

echo; echo "===== 4. INSTALLED PACKAGES ====="
dpkg -l | grep -iE 'wpa|pcsc' || echo "(none matched)"

echo; echo "===== 4b. OFFLINE-INSTALL DEPENDENCY CHECK (critical) ====="
# wpasupplicant 2:2.9.0-21+deb11u3 needs all of these. Only libpcsclite1 is
# cached alongside it; the rest must already exist on the base system.
# libssl1.1 is the tripwire: it exists on bullseye but was REMOVED in bookworm.
# If UniFi OS 5.x moves to bookworm, the cached .deb becomes uninstallable.
for dep in libc6 libdbus-1-3 libnl-3-200 libnl-genl-3-200 libnl-route-3-200 \
           libpcsclite1 libreadline8 libssl1.1 lsb-base adduser; do
  ver=$(dpkg-query -W -f='${Version}' "$dep" 2>/dev/null)
  if [ -n "$ver" ]; then
    printf '  PRESENT  %-20s %s\n' "$dep" "$ver"
  else
    printf '  MISSING  %-20s <-- would break offline dpkg -i\n' "$dep"
  fi
done

echo; echo "===== 5. CERTS AND CONFIG ====="
ls -la /etc/wpa_supplicant/ 2>/dev/null
echo "--- certs dir ---"
ls -la /etc/wpa_supplicant/certs/ 2>/dev/null
echo "--- conf (cert paths must be ABSOLUTE) ---"
cat /etc/wpa_supplicant/wpa_supplicant-wired-eth8.conf 2>/dev/null || \
  echo "(not at expected path; listing /etc/wpa_supplicant)"

echo; echo "===== 6. SYSTEMD UNIT ====="
systemctl status wpa_supplicant-wired@eth8 --no-pager 2>&1 | head -20
echo "--- unit file + any drop-ins ---"
systemctl cat wpa_supplicant-wired@eth8 --no-pager 2>&1 | head -40

echo; echo "===== 7. EXISTING BOOT-SCRIPT PACKAGES (conflict check) ====="
dpkg -l | grep -E 'udm-boot|unifi-on-boot' || echo "(none installed - good, clean slate)"

echo; echo "===== 8. /data LAYOUT ====="
ls -la /data/ 2>/dev/null
echo "--- on_boot.d ---"
ls -la /data/on_boot.d/ 2>/dev/null || echo "(does not exist yet)"

echo; echo "===== 9. MAC CLONE METHOD ====="
ls -la /etc/network/if-up.d/ 2>/dev/null
echo "--- changemac contents, if present ---"
cat /etc/network/if-up.d/changemac 2>/dev/null || echo "(no changemac script - likely using dashboard MAC clone)"
echo "--- current eth8 MAC ---"
ip link show eth8 2>/dev/null

echo; echo "===== 10. ubnt-dpkg-cache CAPABILITY ====="
command -v ubnt-dpkg-cache && ubnt-dpkg-cache --help 2>&1 | head -20

echo; echo "===== 11. SSH STATE ====="
ls -la /root/.ssh/ 2>/dev/null || echo "(no /root/.ssh yet)"

echo; echo "===== 12. RESOURCES ====="
free -h
df -h /data /
uname -m

echo; echo "===== DISCOVERY COMPLETE ====="
