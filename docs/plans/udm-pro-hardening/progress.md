# Progress: UDM Pro Upgrade Readiness and wpa_supplicant Persistence

## Current Status: In Progress

| Phase | Status | Updated | Notes |
|-------|--------|---------|-------|
| 1. Pre-flight discovery | Complete | 2026-08-08 | Found the running config differs from every published recipe |
| 2. Repo + encrypted secrets | Complete | 2026-08-08 | `jcwearn/udm-pro` private, dedicated age key, packages pinned |
| 3. SSH keys | Complete | 2026-08-08 | `udm_ed25519`; PAM keyboard-interactive confirmed as second path |
| 4. unifi-on-boot | Complete | 2026-08-08 | 1.1.3, registered with `ubnt-dpkg-cache` |
| 5. `/data` staging + boot scripts | Complete | 2026-08-08 | Idempotent; converged re-run leaves supplicant PID unchanged |
| 6. Destructive validation | Complete | 2026-08-08 | Full wipe + reboot, self-healed, `CTRL-EVENT-EAP-SUCCESS` |
| 7. Firmware upgrade | Complete | 2026-08-08 | 4.3.6 → 5.1.26; supplicant wiped and rebuilt unaided. Protect → 7.1.87 |
| 8. Documentation | Complete | 2026-08-08 | README runbook, IPS restore checklist |
| 9. UniFi OS 6.0 trixie recovery | In Progress | 2026-11-11 | 5.1.33 → 6.0.17 rebased to trixie; self-heal failed, WAN restored manually. Packages + conf updated; needs a reboot test |

## What discovery changed

The brief assumed `wpa_supplicant-wired@eth8.service` with certs in
`/etc/wpa_supplicant/certs/`. The box actually runs `wpa_supplicant.service`
with an ExecStart override, certs in `/etc/wpa_supplicant/conf/`, and no MAC
cloning at all. The `@`-template unit is present but disabled — following the
brief would have enabled a second, differently configured supplicant while the
real config stayed missing, and the failure would only have surfaced with WAN
already down.

## Decisions

- Secrets SOPS-encrypted with a **dedicated** age identity, separate from the
  k3s cluster key, because the AT&T cert is non-rotatable without new hardware.
- `.deb` packages committed and pinned — Debian pool URLs rot, and the whole
  point is working with no internet.
- Password SSH left enabled. It runs through PAM keyboard-interactive, not
  SSH's own password auth, and is the only recovery path that does not share a
  failure mode with `/data`.
- Network held at the OS-bundled 10.4.57. Ubiquiti does not ship 10.5.x as
  default in their own builds.
- IPS disabled for the upgrade, then restored from snapshot.

## Things that bit, and what they taught

- **`grep` and a leading dash.** The first pre-commit hook used patterns
  starting with `-----BEGIN`, which grep parsed as options, so it matched
  nothing and a test key reached local git history. Fixed with `grep -q --`.
  History was purged before any remote existed. Lesson: test a guard against a
  real positive, not just a clean commit.
- **Ambient `SOPS_AGE_KEY_FILE`.** The shell profile exports one pointing at a
  different identity; `deploy.sh` inherited it and failed opaquely. It now uses
  the repo's own key and validates the identity up front.
- **The IPS toggle destroys configuration.** Turning Threat Management off
  cleared mode, all six networks, all 33 categories and both suppression rules
  from the runtime config *and* the controller database. The snapshot taken
  minutes earlier was the only surviving record.
- **`sshd -T` is misleading.** `passwordauthentication no` coexists with a
  working password login via PAM keyboard-interactive.
- **Case-sensitive `pgrep`.** `pgrep suricata` finds nothing; the process is
  `Suricata-Main`. Briefly concluded IPS was off when it was on at maximum.

## Handoff notes

Everything is verified and documented. `scripts/verify.sh` is the single command
that answers "is this still healthy" — 13 checks, exit 0 when good.

Open items are tracked in the README: Suricata pending migration 6.0.12 → 8.0.6
(blocked once on a stale memory sample, expected to clear on a later cycle).

Protect 7.1.87 landed later the same day — the catalogue had simply not
refreshed when 5.1.26 first reported `Up to Date` at 6.2.88. WAN was unaffected
by the application upgrade, as expected: it rebuilds the app, not the root
filesystem.

Next natural checkpoints: confirm the Suricata 8 migration completes, watch
memory for two weeks, and revisit Network 10.5.x in 1–2 months.

### 2026-11-11 — UniFi OS 6.0.17

The upgrade rebased the box onto Debian 13 trixie. The boot script ran, but the
cached bullseye `wpasupplicant` needed `libssl.so.1.1`, so WAN stayed down and
Protect sat at "Restoring" (it needs internet to reinstall). Recovered over SSH
from the LAN: installed trixie `wpasupplicant` 2.10-24, then added a global
`openssl_ciphers=DEFAULT@SECLEVEL=0` because OpenSSL 3 rejects the SHA-1 /
1024-bit AT&T cert (`ca md too weak`). Details in README, "UniFi OS 6.0 trixie
rebase". `/data/wpa_supplicant/packages/` on the box already holds the trixie
debs; the bullseye ones are kept in `packages.bullseye/` beside it.

Remaining: one reboot to prove the self-heal on trixie (`verify.sh` should pass
afterwards), and confirm Protect finishes reinstalling.
