# Encrypted DNS configuration

Snapshot taken 2026-08-24:
[`dns-config-2026-08-24.json`](./dns-config-2026-08-24.json)

This is a **reference copy, not a restore mechanism.** Encrypted DNS is
configured through the UniFi UI and stored in the controller's own database;
nothing here is applied automatically. It exists because the setting has already
been lost once, silently, and because the UI is not a reliable place to check
whether it is really in effect.

## Settings

| Setting | Value |
|---|---|
| Mode | Custom (not Predefined — NextDNS is not on the built-in list) |
| Server name | `NextDNS` |
| Transport | DNS-over-HTTPS |
| Upstream | `anycast.dns.nextdns.io`, pinned to `45.90.30.0` |
| Listener | `127.0.0.1:5053` |
| Resolver | `dnscrypt-proxy` 2.1.14, bundled at `/usr/sbin/dnscrypt-proxy` |
| Generated config | `/run/dnscrypt-proxy.toml` — tmpfs, rebuilt on each apply |
| Gateway config key | `services.dohProxy` (schema version 3) |
| Controller key | mongo `ace.setting` where `key: "doh"` |

**IPv4 only, deliberately.** This WAN has no global IPv6 address and no default
IPv6 route; HTTPS to NextDNS over IPv6 fails outright. NextDNS publishes dual
stack edge addresses and it is tempting to use them — pinning one here would
black-hole all DNS. UniFi's generated config independently agrees, hardcoding
`ipv6_servers = false`.

**Anycast, not a pinned edge.** `https://router.nextdns.io/?limit=10&stack=dual`
run *from the gateway* reports the nearest edges as `vultr-atl-1` and
`anexia-atl-1`. Pinning one buys nothing measurable — the anycast address already
resolves at 2–9ms typical from here — and costs automatic failover, since one
edge going down would take all DNS with it.

## The stamp

The stamp is a base64 blob that encodes the NextDNS profile ID, so the literal
value is **not** committed here. It decodes to:

```
protocol : 0x02 (DNS-over-HTTPS)
props    : DNSSEC=true NoLogs=true NoFilter=true
addr     : 45.90.30.0
hostname : anycast.dns.nextdns.io
path     : /<nextdns-profile-id>/UDM-Pro
```

`NoLogs` and `NoFilter` are both untrue of a filtered NextDNS profile. They are
inert — the generated `dnscrypt-proxy.toml` sets no `require_*` options, so
nothing ever reads them — and not worth correcting, because the value as it
stands is known to work.

The trailing `/UDM-Pro` is the device name NextDNS attributes queries to. Without
it the dashboard shows the profile but not which device asked.

To rebuild: my.nextdns.io → Setup guide → Routers → DNSCrypt, or paste into
<https://dnscrypt.info/stamps/> and edit the path.

Two format traps:

- The UI expects the value **with** the `sdns://` prefix. The gateway config
  stores it in `sdnsStamp` **without** the prefix. They are the same stamp.
- The live value can be read back off the box while the resolver is running, so
  a lost UI entry does not mean a lost stamp — see *Checking state*.

## Confirmed: the setting does not survive a re-provision on its own

Configured 2026-08-18, working within a minute, gone four days later with the UI
showing an empty stamp field. Reconstructed from the config generations kept in
`/data/udapi-config/`, the resolver log, and the journal:

| When | Event |
|---|---|
| 2026-08-18 16:42 | gen `3a6c0a79` — `services.dohProxy` absent |
| 2026-08-18 17:00 | gen `9a86317d` — `services.dohProxy` present |
| 2026-08-18 17:01 | `[NextDNS] OK (DoH) - rtt: 30ms`, `live servers: 1` |
| 2026-08-20 18:32:37 | gen `4b5b3985` — still present |
| 2026-08-20 18:32:57 | gen `f3ebc49f` — **absent** |
| 2026-08-20 18:33:01 | `svc-doh-proxy-service: Stop running->deleted service dnscrypt-proxy` |

Meanwhile the controller's own record read:

```json
{ "state": "off", "server_names": [], "custom_servers": [], "key": "doh" }
```

`custom_servers` is the list of servers *defined*; `server_names` is the list
*selected*. Both were empty while the gateway was actively running the resolver.

That divergence is the entire failure. The gateway held configuration the
controller had no record of, so the next full reconcile deleted it — correctly,
by its own logic. Nothing was upgraded that day (`/var/log/dpkg.log` shows no
package activity after 2026-08-08), which means **any re-provision triggers
this, not just a firmware upgrade.**

The practical consequence: *the resolver running is not evidence that the setting
is saved.* It ran for two days in that state. Verify against the controller.

## Restore checklist

Settings → CyberSecure → Protection → Encrypted DNS → **Custom**, then:

1. **Server Name** → `NextDNS`; **DNS Stamp** → the `sdns://` value
2. **Add** — the entry must appear in the list. Skipping this is the most likely
   way to end up with `custom_servers: []` while the gateway still gets a push
3. **Select** the entry so it becomes active — otherwise `server_names` stays
   empty and `state` never flips to `on`
4. Apply Changes
5. Confirm the controller committed it, not just the gateway:
   ```bash
   ssh udm 'mongo --quiet --port 27117 ace --eval "db.setting.find({key:\"doh\"}).forEach(function(d){print(JSON.stringify(d))})"'
   # expect: state "on", custom_servers non-empty, server_names non-empty
   ```
6. Re-run `scripts/verify.sh` after the next unrelated settings change, to catch
   a reconcile rather than trusting the first apply

## Checking state

```bash
# controller's record — the authoritative one, and the one that was wrong
ssh udm 'mongo --quiet --port 27117 ace --eval "db.setting.find({key:\"doh\"}).forEach(function(d){print(JSON.stringify(d))})"'

# gateway config. Select dohProxy specifically: services.ddns alongside it
# holds the DDNS account password in plaintext.
ssh udm 'python3 -c "import json;print(json.load(open(\"/data/udapi-config/udapi-net-cfg.json\"))[\"services\"].get(\"dohProxy\"))"'

# running resolver, and the live stamp
ssh udm 'ss -lnup | grep 5053; grep stamp /run/dnscrypt-proxy.toml'
ssh udm 'tail -5 /var/log/dnscrypt-proxy.log'
```

Confirm end to end at <https://my.nextdns.io> — queries should land on the
profile and be attributed to `UDM-Pro`. "This device is using NextDNS with no
profile" means the path portion of the stamp is not reaching the resolver.

UI path: Settings → CyberSecure → Protection → Encrypted DNS.
