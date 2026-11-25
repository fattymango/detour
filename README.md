# Detour

A self-hosted, split-tunnel VPN: run `detour-server` on your own box, connect your phone to it, and pick exactly which apps route through it. Built because WireGuard gets blocked by some networks' DPI and OpenVPN has no clean embeddable Android library — Detour disguises its traffic as plain TLS on port 443.

- **Per-app tunneling** — only the apps you choose use the VPN; everything else bypasses it at the OS level.
- **Light on battery** — sleeps until there is traffic, with a brief check every few minutes instead of constant heartbeats.
- **Rests when not in use** — after a time you choose, it can turn off, or go on standby and reconnect when you open one of its apps.
- **One-time invites** — a link works for the first phone that adds it, and logins are stored encrypted.
- **Home-screen widget** — connect and disconnect with one tap.
- **Per-user limits** — admins set each user's speed and total data in the app; the server enforces them.
- **No central service, no accounts with a third party** — you run the server, you own the user list.

## Layout

```
server/              Go tunnel server (detour-server) — run this on your own machine
packages/detour_vpn/ Flutter plugin: the VPN engine (Dart API + Android VpnService) — install it in any app
app/                 Thin demo Flutter app built on detour_vpn
```

Everything is designed to be used independently: `detour-server` is a single Go binary with no Flutter dependency, and `detour_vpn` is a normal Flutter plugin you can add to your own app's `pubspec.yaml` without touching `app/` at all.

## Quick start

1. **Server**: follow [`server/README.md`](server/README.md). It ends with an invite link for your admin account.
2. **App** (Android 8 or newer): install the APK from [Releases](https://github.com/fattymango/detour/releases), usually `detour-android-arm64-v8a.apk`. Or build it with [Flutter](https://docs.flutter.dev/get-started/install): `cd app && flutter run`.
3. In the app, tap **+**, paste the invite link, and tap **Add**. Pick your apps under **⋮ → Select apps**, then tap the server to connect.
4. Invite other people under **⋮ → Manage users**.

Maintainers build the downloads with [`scripts/release.sh`](scripts/release.sh). Building your own app? Use the [`detour_vpn`](packages/detour_vpn/README.md) package.

## How it works

The client opens a TLS connection to the server, authenticates with a username/password (bcrypt-checked server-side), and gets back an assigned IP. From then on both sides just relay length-prefixed raw IP packets between the phone's TUN interface and the server's TUN interface, which is NAT'd to the internet. The server's self-signed certificate is pinned by its exact SHA-256 fingerprint instead of validated against a CA — there's no domain, so there's nothing for a public CA to vouch for. Full protocol details are in [`server/README.md`](server/README.md).

## License

MIT — see [LICENSE](LICENSE).
