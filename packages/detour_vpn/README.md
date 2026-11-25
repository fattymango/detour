# detour_vpn

A Flutter plugin for a self-hosted, split-tunnel VPN that talks to [`detour-server`](../../server). Add it to any Flutter app's `pubspec.yaml` to get:

- Per-app tunneling (only the apps you pick route through the VPN — everything else bypasses it at the OS level)
- A single background `VpnService`, with a wake lock and a 15-second heartbeat only while connected
- Admin calls to list, add, limit, reset and remove a server's users (`listServerUsers` and friends), for configs whose user is an admin
- A home-screen widget that toggles the last-used config (remove it with `tools:node="remove"` on `com.detour.vpn.VpnWidgetProvider` in your manifest)
- A connection log and live status stream

Currently Android only (`android.net.VpnService`). No iOS implementation exists yet — contributions welcome.

## Install

```yaml
dependencies:
  detour_vpn:
    git:
      url: https://github.com/fattymango/detour.git
      path: packages/detour_vpn
```

Your app needs `minSdk` 26 or higher.

## Usage

```dart
import 'package:detour_vpn/detour_vpn.dart';

final vpn = VpnRepository();

// One-time: import an invite link, then choose the apps to tunnel.
// Without any, every app except yours uses the VPN.
await vpn.importConfig(name: 'home', text: 'detour://alice:s3cret@203.0.113.7:443/<fingerprint>?name=home');
await vpn.setIncludedApps('home', ['com.some.app', 'com.other.app']);

if (!await vpn.hasVpnPermission()) {
  await vpn.requestVpnPermission();
}
await vpn.connect('home');

vpn.watchStatus().listen((status) => print(status.state));
```

Invite links are `detour://user:password@host:port/fingerprint?name=suggested`, with the values percent-encoded. `importConfig` also accepts `key: value` lines for `host`, `port`, `username`, `password`, `fingerprint` and `apps`. `previewConfig` checks either without saving.

See [`tunnel_config.dart`](lib/src/models/tunnel_config.dart) for the config shape and [`vpn_repository.dart`](lib/src/vpn_repository.dart) for the full API (list/rename/delete configs, per-app allow-list, logs, battery-optimization exemption).

## How it works

The Dart API talks to a native `TunnelVpnService` over a Flutter method/event channel. The service owns a TUN interface and relays raw IP packets to `detour-server` over a certificate-pinned TLS connection (see the [server README](../../server/README.md) for the wire protocol). Split-tunneling is just `VpnService.Builder.addAllowedApplication` for the packages in a config's `apps` list.
