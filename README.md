# udm-pro

Configuration-as-code for a UniFi Dream Machine Pro on AT&T fiber, where the
residential gateway is bypassed by running the EAP-TLS 802.1X supplicant on the
UDM itself.

**The problem this solves:** UniFi OS upgrades rebuild the root filesystem and
delete `wpasupplicant`. With no supplicant, 802.1X fails, WAN drops, and there
is no internet available to `apt install` it back — recovery meant physically
reconnecting the AT&T gateway. That is why firmware sat frozen at UniFi OS 4.3.6
for over a year, which in turn meant missing security fixes.

Now the box restores itself from `/data` on boot, and upgrades are hands-off.

This repo owns the OS layer: UniFi OS, the supplicant, the boot scripts, and
the upgrade runbook. The Network application's configuration (networks,
firewall, WLANs) is owned by [jcwearn/unifi-infra](https://github.com/jcwearn/unifi-infra)
through the API.

## Verified

| | Result |
|---|---|
| Destructive test — package, certs, conf, drop-in, enable symlink and `authorized_keys` all deleted, then rebooted | Self-healed, `CTRL-EVENT-EAP-SUCCESS`, no gateway needed |
| Real UniFi OS 4.3.6 → 5.1.26 upgrade | Firmware wiped the supplicant, box rebuilt it, ~49s from boot script to authenticated WAN |

## Current state

| Component | Version |
|---|---|
| UniFi OS | 5.1.33 (`UDMPRO.al324.v5.1.33.44ce47b.260909.0025`) |
| Network | 10.6.106 |
| Protect | 7.2.105 |
| Debian base | 11 bullseye |
| wpasupplicant | 2:2.9.0-21+deb11u3 |
| unifi-on-boot | 1.1.3 |

## How the self-heal works

`unifi-on-boot` survives firmware rebuilds via a systemd unit in the preserved
overlay, a backup `.deb` in `/data/unifi-on-boot/`, and registration with
`ubnt-dpkg-cache`. On boot it runs `/data/on_boot.d/*` in sorted order:

| Script | Restores |
|---|---|
| `05-ssh-keys.sh` | `/root/.ssh/authorized_keys` from `/data/ssh/` |
| `06-wpa-supplicant.sh` | package (offline `dpkg -i`), certs, conf, systemd drop-in, enable symlink |

SSH keys go first so a supplicant failure still leaves you able to log in and
debug. Both are no-ops on an ordinary reboot — every step is guarded, and
re-running against a converged system leaves the supplicant PID unchanged.

### The configuration that actually matters

Published UDM recipes describe a different setup from the one running here.
Following them would have produced a restore path that silently did nothing:

| Common recipe | Reality on this box |
|---|---|
| `wpa_supplicant-wired@eth8.service` | `wpa_supplicant.service` + ExecStart override |
| certs in `/etc/wpa_supplicant/certs/` | certs in `/etc/wpa_supplicant/conf/` |
| MAC clone required | not used — cert identity ≠ eth8 MAC, auth succeeds anyway |

The `@`-template unit exists and is **disabled**. Enabling it would start a
second, differently configured supplicant.

The load-bearing file is
`/etc/systemd/system/wpa_supplicant.service.d/override.conf`, which supplies
`-Dwired -ieth8`. Without it the service still reports `active` while
authenticating nothing. That silent-success mode is why `06-wpa-supplicant.sh`
compares drop-in *content* rather than existence, and why `verify.sh` asserts on
the process command line rather than unit state.

Cert filenames are load-bearing too — `wpa_supplicant.conf` hardcodes absolute
paths to the full extraction-tool names.

## Usage

```bash
scripts/deploy.sh [host]    # decrypt secrets, stage /data, install boot scripts
scripts/verify.sh [host]    # 16-point health check, exit 0 = all good
scripts/discover.sh         # read-only audit; run via ssh, see below
```

Default host is `udm` (see `~/.ssh/config`). Run `verify.sh` after any change,
after a reboot, and after every firmware upgrade.

```bash
# post-upgrade audit, while the gateway is still reachable
ssh udm 'bash -s' < scripts/discover.sh > /tmp/discovery.txt
```

## Secrets

The AT&T EAP-TLS client certificate is extracted from the BGW gateway firmware
and **cannot be reissued without new hardware**. A credential you cannot rotate
should not sit in plaintext anywhere you rely on someone else's access control,
so `secrets/` is SOPS-encrypted with a dedicated age identity — separate from
any other key, so the blast radii stay independent.

```bash
# decrypt one file
SOPS_AGE_KEY_FILE=~/.config/sops/age/router.txt \
  sops -d --input-type binary --output-type binary \
  secrets/Client_001E46-R91VH9PP100534.pem.sops
```

Recipient: `age16uza3xc48h3lftfenx27yzpxx9gn9n33yxlz0tw4vwfs037qpecsv28qhj`

**The age private key lives in the password manager and nowhere else in this
repo.** Lose it and `secrets/` is unrecoverable. `scripts/deploy.sh`
deliberately does **not** honour an ambient `SOPS_AGE_KEY_FILE` (the shell
profile sets one pointing at a different identity); override with
`UDM_AGE_KEY_FILE` if needed.

`.githooks/pre-commit` blocks plaintext PEMs even under `git add -f`. Install it
with `git config core.hooksPath .githooks` after cloning.

Cert validity runs to **2039**.

## SSH access

Two independent paths, which is the point:

1. **Key** — `~/.ssh/udm_ed25519`, restored from `/data/ssh/authorized_keys` by
   `05-ssh-keys.sh`.
2. **Password** — via PAM. Note `sshd -T` reports `passwordauthentication no`,
   which is misleading: `kbdinteractiveauthentication yes` + `usepam yes` means
   PAM prompts for the root password through keyboard-interactive. The server
   offers `publickey,keyboard-interactive`.

Path 2 depends on sshd + PAM + the UniFi-managed root password, none of which
live in `/data`. So if `/data` were lost entirely, that login still works. Do
not disable it — it is the only recovery route that does not share a failure
mode with everything else here.

## Restore from scratch

Bare UDM to working bypass, assuming `/data` is empty:

1. Temporarily reconnect the AT&T gateway upstream for LAN/WAN access.
2. `ssh-copy-id -i ~/.ssh/udm_ed25519.pub udm` (password via keyboard-interactive).
3. `scp packages/unifi-on-boot_*.deb udm:/tmp/ && ssh udm 'dpkg -i /tmp/unifi-on-boot_*.deb'`
4. `scripts/deploy.sh udm`
5. `ssh udm 'systemctl restart unifi-on-boot'`
6. `scripts/verify.sh udm` → expect ALL CHECKS PASSED
7. Disconnect the AT&T gateway; WAN should hold.

## Upgrade procedure

1. Confirm `scripts/verify.sh` passes.
2. Note the current `.unf` autobackups exist (`/data/unifi/data/backup/autobackup/`,
   daily 04:00). There is no separate console-level backup on this platform —
   the `.unf` is it. Pull copies to `~/udm-pro-backups/` (kept outside this repo;
   they contain site credentials and the pre-commit hook cannot detect them in a
   binary).
3. Disable IPS — see [`docs/ips-config.md`](docs/ips-config.md).
4. Upgrade UniFi OS.
5. **Immediately re-run `scripts/verify.sh`.** The critical line is the base
   check: the cached `.deb` is bullseye-era and `libssl1.1` does not exist on
   bookworm. If UniFi OS ever rebases, refresh `packages/` **while the gateway
   is still reachable**, before trusting the cache.
6. Re-enable IPS from the checklist and diff against the snapshot.
7. Confirm Encrypted DNS is still committed — see [`docs/dns-config.md`](docs/dns-config.md).
   `verify.sh` checks this, but it reverts on any re-provision, not only upgrades.

### Version policy

Do not freeze. Freezing is not free — it cost a year of security fixes last
time.

Device firmware auto-updates daily at 3 AM. UniFi OS, Network and Protect
application updates are applied by hand; auto-update is off for all three.
Network has moved 10.4.57 → 10.5.67 → 10.6.101 → 10.6.106 between 2026-08-08
and 2026-09-15, so "Current state" above reflects the box as last checked, not
a pin.

## Known open items

**Suricata is stuck on 6.0.12.** UniFi OS 5.1.26 ships both `ips_6/` and
`ips_8/` engines and migrates when memory allows. The migration was refused:

```
available memory without suricata: 792,924,343 B (~756 MB)
target evaluation memory usage:    661,314,517 B (~631 MB)  is insufficient
```

Note the sample timestamp in that log line is 24h old — it evaluated against the
pre-cleanup memory profile, when IPS was running at High and ~770 MB was free.
Current headroom is far better, so a later evaluation cycle should succeed. IPS
works normally on 6.0.12 in the meantime.

**Encrypted DNS reverts unless the controller commits it.** NextDNS over DoH
was configured on 2026-08-18, ran for two days, and was deleted on 2026-08-20 by
an ordinary config reconcile — no upgrade involved. The gateway had the resolver
running while the controller's `doh` setting still read `state: off` with an
empty `custom_servers`, so the reconcile was right to remove it. The stamp was
never at fault. Because the resolver running proves nothing, `verify.sh` asserts
on the controller's record; see [`docs/dns-config.md`](docs/dns-config.md).

**`apt-get update` exits 100.** `bullseye-backports` in `/etc/apt/sources.list`
was archived by Debian and 404s. It breaks apt generally but affects nothing
here — the restore path uses `dpkg -i` against the local cache and never touches
apt.

## Future option, not implemented

Move the supplicant off the UDM entirely — a Raspberry Pi or mini PC between the
ONT and the UDM running wpa_supplicant, or [eap_proxy](https://github.com/kangtastic/eap_proxy).
UniFi firmware then becomes irrelevant to WAN connectivity, at the cost of one
more device in the critical path. Less compelling now that upgrades are proven
hands-off, but worth revisiting if Ubiquiti's release cadence gets rougher.

## References

- [unifi-on-boot](https://github.com/unredacted/unifi-on-boot)
- [Unifi-gateway-wpa-supplicant](https://github.com/evie-lau/Unifi-gateway-wpa-supplicant)
- [AT&T cert extraction (BGW210/BGW320)](https://github.com/0x888e/certs)
