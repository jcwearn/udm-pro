#1 Make the AT&T 802.1X bypass survive firmware upgrades
merged: 2026-08-08T15:30:18Z

Sets up the repo, the encrypted credentials, and the boot-time restore path so
a UniFi OS upgrade no longer drops WAN and require reconnecting the AT&T gateway.

## What discovery changed

The working configuration on the box is not the one the published UDM recipes
describe. Three corrections, all verified live:

| Assumed | Actual |
|---|---|
| `wpa_supplicant-wired@eth8.service` | `wpa_supplicant.service` + ExecStart override |
| certs in `/etc/wpa_supplicant/certs/` | certs in `/etc/wpa_supplicant/conf/` |
| MAC clone needed | not used — identity ≠ eth8 MAC, auth succeeds anyway |

The `@`-template unit exists but is **disabled**. Enabling it, as the standard
recipe does, would have started a second differently-configured supplicant
while the real config stayed missing.

## Why the drop-in matters most

`/etc/systemd/system/wpa_supplicant.service.d/override.conf` is what supplies
`-Dwired -ieth8`. Without it the service still reports `active` while
authenticating nothing. That silent-success failure mode is why:

- `10-wpa-supplicant.sh` compares drop-in *content*, not mere existence
- `verify.sh` asserts on the process command line, not unit state

## Contents

- `secrets/` — CA, client cert, PKCS1 key and conf, SOPS binary mode, dedicated age key
- `packages/` — wpasupplicant + libpcsclite1 + unifi-on-boot, pinned with SHA256
- `on_boot.d/` — SSH key restore, then supplicant restore; both no-ops on a normal reboot
- `scripts/` — `discover.sh` (read-only audit), `deploy.sh`, `verify.sh`
- `.githooks/pre-commit` — blocks plaintext PEMs even under `git add -f`

## Known risk carried forward

`wpasupplicant` needs ten dependencies, not just `libpcsclite1`. Nine come from
the base image. `libssl1.1` is the tripwire — bullseye-only, removed in bookworm.
If UniFi OS 5.x rebases, the cached `.deb` stops installing. `verify.sh` checks
this explicitly; re-run it post-upgrade while the gateway is still reachable.

---

Archived here because the repository was deleted and recreated to publish it, which
destroys `refs/pull/*` along with the pull request page. The diff survives in the commit
history; this is the description that would otherwise have gone with it.
