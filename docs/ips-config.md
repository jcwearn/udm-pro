# IPS/IDS configuration

Snapshot taken 2026-08-08 before the UniFi OS 5.1.26 upgrade:
[`ips-config-2026-08-08.json`](./ips-config-2026-08-08.json)

This is a **reference copy, not a restore mechanism.** Threat Management is
configured through the UniFi UI and stored in the controller's own config;
nothing here is applied automatically. It exists so the settings can be
reconstructed by hand if a toggle or an upgrade loses them.

## Settings at snapshot time

| Setting | Value |
|---|---|
| Enabled | yes |
| Mode | `pcap-l3-blocking-high` — blocking (IPS), High sensitivity |
| Interfaces | `br0`, `br2`, `br10`, `br20`, `br40`, `br100` |
| Block time | 300s |
| Signature refresh | every 24h |
| Tor / alien blocking | both on |
| Signature categories | 33, all set to `block` |
| Resident memory | ~651 MB (largest single consumer on the box) |

## The part that is easy to lose

Two custom **suppression rules**, both for SID `2003068`, gid `1`:

| id | track | networks |
|---|---|---|
| 1 | source | `<lan-ip-1>/32`, `<lan-ip-2>/32`, `<lan-ip-3>/32` |
| 2 | destination | `<lan-ip-1>/32`, `<lan-ip-2>/32`, `<lan-ip-3>/32` |

These are hand-tuned exceptions. Everything else in the config is reachable
from the UI in a few clicks; these are the entries worth checking explicitly
after any Threat Management toggle or firmware upgrade, because losing them
reintroduces whatever false positive they were added to silence.

## What is NOT affected by the IPS toggle

Region blocking is a **separate service**, `services.geoipFiltering`, not part
of `services.idsIps`:

```
enabled: true, action: block, direction: incoming
countryList: RU BY AM KZ KG CU CN
interfaces: eth8, eth9        (WAN — note IPS runs on the six br* bridges)
```

It is enforced with ipset + iptables (`UBIOS*` hash:net sets), and there is no
geoip reference anywhere in Suricata's yaml. Turning Intrusion Prevention off
leaves country blocking fully in place. Worth writing down because both live
under the same "CyberSecure → Protection" page in the UI, which makes them look
like one feature.

Also on that page but unrelated to IPS: Encrypted DNS, Honeypot,
Identification (DPI), Content Filter, Traffic Logging.

## Why IPS is disabled during the OS upgrade

UniFi OS 5.1.26 ships Suricata 8.0.6. Community reports include a Suricata 8
migration failing with `INSUFFICIENT_MEMORY`, and this console runs the
heaviest available configuration (blocking + High + six bridges) on a box with
roughly 772 MB available of 3946 MB total. Disabling Threat Management before
the upgrade frees ~651 MB and takes the Suricata migration out of the upgrade's
critical path entirely.

Re-enable after the upgrade is verified, then watch memory for two weeks.

## Checking state

```bash
# running engine — the -i matters, the process is "Suricata-Main"
ssh udm 'pgrep -ai suricata'

# authoritative setting
ssh udm 'python3 -c "import json;print(json.load(open(\"/data/udapi-config/udapi-net-cfg.json\"))[\"services\"][\"idsIps\"])"'
```

UI path: Settings → Security → Threat Management.
