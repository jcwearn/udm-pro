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

This repo owns the OS layer: UniFi OS, the supplicant, Tailscale, the boot
scripts, and the upgrade runbook. The Network application's configuration (networks,
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
| Tailscale | 1.102.4 (static arm64 build, manual bump — see [Tailscale](#tailscale)) |

## How the self-heal works

`unifi-on-boot` survives firmware rebuilds via a systemd unit in the preserved
overlay, a backup `.deb` in `/data/unifi-on-boot/`, and registration with
`ubnt-dpkg-cache`. On boot it runs `/data/on_boot.d/*` in sorted order:

| Script | Restores |
|---|---|
| `05-ssh-keys.sh` | `/root/.ssh/authorized_keys` from `/data/ssh/` |
| `06-wpa-supplicant.sh` | package (offline `dpkg -i`), certs, conf, systemd drop-in, enable symlink |
| `07-tailscale.sh` | binaries from the staged tarball (hash-checked), `tailscaled.service`, enable + start; node identity already in `/data` |

SSH keys go first so a supplicant failure still leaves you able to log in and
debug. Tailscale goes last: it needs WAN, WAN does not need it, and nothing
about the tailnet may delay 802.1X. All three are no-ops on an ordinary reboot
— every step is guarded, and re-running against a converged system leaves the
supplicant PID unchanged.

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
scripts/verify.sh [host]    # health check, exit 0 = all good
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

## Tailscale

The router is a plain tailnet node named `router`, so `ssh router` works over
MagicDNS from any device with Tailscale's DNS override on. It is nothing else:
no subnet routes, no exit node, no accepted routes, no Tailscale SSH, and —
the one that matters — `--accept-dns=false`, because the UDM is the LAN's
resolver and Tailscale must never rewrite its `/etc/resolv.conf`. `verify.sh`
asserts every one of those from the daemon's own prefs, plus the absence of
`100.100.100.100` in `resolv.conf`.

Layout, all under `/data/tailscale/` so a firmware rebuild loses nothing that
matters:

| Path | What |
|---|---|
| `tailscale_<version>_arm64.tgz` + `SHA256SUMS` | the official static build, pinned; staged by `deploy.sh` |
| `bin/tailscale`, `bin/tailscaled` | extracted by `07-tailscale.sh` when missing or the wrong version |
| `tailscaled.service` | the unit, copied to `/etc/systemd/system` on every boot that finds it gone or different |
| `tailscaled.state` | the node identity; written by `tailscaled`, never by this repo |

After a UniFi OS upgrade the unit file is the only casualty; the boot script
puts it back, `tailscaled` reads its key from `/data`, and the node rejoins on
its own. **No auth key is stored on the box or in this repo.** The CLI is
`/data/tailscale/bin/tailscale`; nothing is put on `PATH`.

### The one-time join

`07-tailscale.sh` never runs `tailscale up`. On a node that has not joined (or
was logged out on purpose) it prints this and exits 0:

```bash
ssh udm
/data/tailscale/bin/tailscale up --accept-dns=false --accept-routes=false --advertise-routes= --ssh=false --hostname=router
```

Either append `--auth-key=tskey-auth-...` or follow the login URL it prints.
Flags are not persisted between `tailscale up` runs, so if you ever re-run it,
pass all of them again. Then `scripts/verify.sh` from the Mac, and
`ssh router` from anywhere with Tailscale on.

Then disable key expiry for `router` in the admin console (Machines → … →
Disable key expiry); otherwise the node key lapses after 180 days, `tailscaled`
drops to `NeedsLogin`, and the join has to be repeated.

### What Tailscale changes on the box, and what is not yet verified

Relied upon, from the 1.102.4 source:

- Tailscale detects Ubiquiti hardware by `/usr/bin/ubnt-device-info` and takes
  a UBNT-specific policy-routing path: a single `ip rule` at pref 5270
  (`not fwmark 0x80000/0xff0000 lookup 52`) rather than the four rules it
  installs elsewhere. Table 52 holds only tailnet routes.
- With the default `--netfilter-mode=on` and `iptables` present, it creates
  chains `ts-input` and `ts-forward` in `filter` and `ts-postrouting` in
  `nat`, and inserts a jump to each at position 1 of `INPUT`, `FORWARD` and
  `POSTROUTING`. `ts-input` accepts traffic arriving on `tailscale0` and
  `udp --dport 41641` on every interface, `eth8` included; `ts-forward` marks
  and accepts forwarded traffic in and out of `tailscale0`; nothing is
  forwarded because no routes are advertised or accepted. UniFi's `UBIOS_*`
  chains stay below, untouched.
- That `ts-input` rule is the one WAN-facing change the router gains: UDP
  41641 is open inbound on WAN, ahead of UniFi's drop rules, which is what lets
  peers connect direct instead of through DERP. Anything that is not a valid
  WireGuard handshake from a tailnet peer is silently dropped by `tailscaled`;
  nothing else listens there. Rollback is the [Rollback](#rollback) section:
  `tailscale logout` plus disabling the unit, whose `--cleanup` removes the
  chains.
- Tailscale's WireGuard traffic leaves on `eth8`. IPS inspects only the six
  `br*` bridges, and the Peer-to-Peer category was already unchecked in the
  snapshot ("2 of 3"), which is what
  [Tailscale's firewall doc](https://tailscale.com/docs/integrations/firewalls)
  asks of UniFi threat detection.
- The community [tailscale-udm](https://github.com/SierraSoftworks/tailscale-udm)
  package runs kernel-TUN Tailscale on this hardware family with the same
  `--state /data/tailscale/tailscaled.state` layout. It is not used here
  because it installs through `apt`, which is broken on this box, and reinstalls
  from the internet on every firmware update; this repo installs offline from
  the pinned tarball instead.

Not verifiable until the first `deploy.sh` + `verify.sh` run on the box:

- that `/dev/net/tun` is usable so `tailscale0` comes up in kernel mode rather
  than needing `--tun=userspace-networking` (`verify.sh` checks the interface);
- that the box's `fwmark` use does not collide with Tailscale's `0x80000` /
  `0x40000` in mask `0xff0000` (`verify.sh` prints whether the `ts-*` chains
  hooked in; `journalctl -u tailscaled` shows the netfilter mode it chose);
- whether peers connect direct or through DERP (`tailscale status` shows
  `direct` or `relay` per peer).

### Upgrading Tailscale

Renovate cannot bump this: the shared preset only regex-matches `.tf` and
workflow files, and a version-only bump would leave the committed tarball and
its hash stale. By hand:

```bash
v=1.103.0   # from https://pkgs.tailscale.com/stable/
curl -fsSLO "https://pkgs.tailscale.com/stable/tailscale_${v}_arm64.tgz"
curl -fsSL  "https://pkgs.tailscale.com/stable/tailscale_${v}_arm64.tgz.sha256"   # compare
git rm packages/tailscale_*_arm64.tgz && mv "tailscale_${v}_arm64.tgz" packages/
# replace the tailscale line in packages/SHA256SUMS, bump the version above, then:
scripts/deploy.sh && ssh udm 'systemctl restart unifi-on-boot' && scripts/verify.sh
```

`deploy.sh` sends the 34 MB tarball only when the box does not already hold a
matching copy, and removes any other `tailscale_*_arm64.tgz` there, because the
boot script reads the pinned version from the filename.

### Rollback

```bash
ssh udm '/data/tailscale/bin/tailscale logout; systemctl disable --now tailscaled.service'
```

then remove the machine in the admin console. The boot script stays installed
and harmless: on the next boot it restores the unit, starts the daemon, sees
`NeedsLogin`, prints the join command and exits 0. To remove it entirely,
revert the Tailscale change in this repo (the boot script, the unit, the
tarball and its `SHA256SUMS` line, and the Tailscale blocks in `deploy.sh` and
`verify.sh`), then delete `/data/on_boot.d/07-tailscale.sh` and
`/data/tailscale/` on the box by hand — `deploy.sh` only adds boot scripts, it
never removes one.

## Restore from scratch

Bare UDM to working bypass, assuming `/data` is empty:

1. Temporarily reconnect the AT&T gateway upstream for LAN/WAN access.
2. `ssh-copy-id -i ~/.ssh/udm_ed25519.pub udm` (password via keyboard-interactive).
3. `scp packages/unifi-on-boot_*.deb udm:/tmp/ && ssh udm 'dpkg -i /tmp/unifi-on-boot_*.deb'`
4. `scripts/deploy.sh udm`
5. `ssh udm 'systemctl restart unifi-on-boot'`
6. `scripts/verify.sh udm` → expect the Tailscale checks to fail with
   `NeedsLogin`; everything else passes.
7. Disconnect the AT&T gateway; WAN should hold.
8. The node identity was in `/data`, so it is gone too: do the
   [one-time join](#the-one-time-join) again by hand, then `scripts/verify.sh`
   → expect ALL CHECKS PASSED.

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
   is still reachable**, before trusting the cache. The same run verifies
   `tailscaled` after the reboot: unit restored, `Running`, identity still in
   `/data`. If it reports `NeedsLogin`, `/data/tailscale/tailscaled.state` did
   not survive and the join is repeated by hand.
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

Tailscale is the one row that *is* a pin, and a manual one — see
[Upgrading Tailscale](#upgrading-tailscale).

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

## Future options, not implemented

**A fallback subnet router.** The router could advertise the LAN routes so the
tailnet can reach the LAN when the k3s subnet router is down, independent of
the cluster — see `docs/plans/dns-remote-access-resilience.md` in
[k3s-cluster](https://github.com/jcwearn/k3s-cluster). Deliberately not done
here: the join above advertises nothing, and `verify.sh` will fail if that
changes without this section changing with it.

**Move the supplicant off the UDM entirely** — a Raspberry Pi or mini PC
between the ONT and the UDM running wpa_supplicant, or
[eap_proxy](https://github.com/kangtastic/eap_proxy).
UniFi firmware then becomes irrelevant to WAN connectivity, at the cost of one
more device in the critical path. Less compelling now that upgrades are proven
hands-off, but worth revisiting if Ubiquiti's release cadence gets rougher.

## References

- [unifi-on-boot](https://github.com/unredacted/unifi-on-boot)
- [tailscale-udm](https://github.com/SierraSoftworks/tailscale-udm) — the
  community package; the `/data/tailscale` state layout is borrowed from it
- [Tailscale static binaries](https://pkgs.tailscale.com/stable/) and the
  [`tailscale up` flags](https://tailscale.com/kb/1241/tailscale-up)
- [Unifi-gateway-wpa-supplicant](https://github.com/evie-lau/Unifi-gateway-wpa-supplicant)
- [AT&T cert extraction (BGW210/BGW320)](https://github.com/0x888e/certs)
