# Detour

A self-hosted, split-tunnel VPN: run `detour-server` on your own box, connect your phone to it, and pick exactly which apps route through it. Built because WireGuard gets blocked by some networks' DPI and OpenVPN has no clean embeddable Android library — Detour disguises its traffic as plain TLS on port 443.

- **Per-app tunneling** — only the apps you choose use the VPN; everything else bypasses it at the OS level.
- **Low battery use** — one background service, no polling, a wake lock held only while actually connected.
- **Per-user limits** — admins set each user's speed and total data in the app; the server enforces them.
- **No central service, no accounts with a third party** — you run the server, you own the user list.

## Layout

```
server/              Go tunnel server (detour-server) — run this on your own machine
packages/detour_vpn/ Flutter plugin: the VPN engine (Dart API + Android VpnService) — install it in any app
app/                 Thin demo Flutter app built on detour_vpn
```

Everything is designed to be used independently: `detour-server` is a single static-ish Go binary with no Flutter dependency, and `detour_vpn` is a normal Flutter plugin you can add to your own app's `pubspec.yaml` without touching `app/` at all.

## Quick start

1. **Server**: see [`server/README.md`](server/README.md) — generate a cert, add a user, run the binary.
2. **App**: see [`packages/detour_vpn/README.md`](packages/detour_vpn/README.md) for the API, or just build `app/` directly:
   ```bash
   cd app
   flutter pub get
   flutter run
   ```
3. In the app, tap **+** and paste the config text `detour-server adduser` gave you (plus the cert fingerprint), then connect.

## How it works

The client opens a TLS connection to the server, authenticates with a username/password (bcrypt-checked server-side), and gets back an assigned IP. From then on both sides just relay length-prefixed raw IP packets between the phone's TUN interface and the server's TUN interface, which is NAT'd to the internet. The server's self-signed certificate is pinned by its exact SHA-256 fingerprint instead of validated against a CA — there's no domain, so there's nothing for a public CA to vouch for. Full protocol details are in [`server/README.md`](server/README.md).

## License

MIT — see [LICENSE](LICENSE).
