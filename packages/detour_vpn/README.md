# detour_vpn

A Flutter plugin for a self-hosted, split-tunnel VPN that talks to [`detour-server`](../../server). Add it to any Flutter app's `pubspec.yaml` to get:

- Per-app tunneling (only the apps you pick route through the VPN — everything else bypasses it at the OS level)
- Low battery use (a single background `VpnService` + wake lock held only while connected, no polling)
- Built-in DNS-level ad blocking
- A connection log and live status stream

Currently Android only (`android.net.VpnService`). No iOS implementation exists yet — contributions welcome.

## Install

```yaml
dependencies:
  detour_vpn:
    path: ../packages/detour_vpn   # or a pub.dev/git reference once published
```

## Usage

```dart
import 'package:detour_vpn/detour_vpn.dart';

final vpn = VpnRepository();

// One-time: paste the config text detour-server's `adduser` output gives you
// (host/port/username/password/fingerprint), plus a comma-separated list of
// package names to tunnel.
await vpn.importConfig(name: 'home', text: '''
host: 203.0.113.7
port: 443
username: alice
password: s3cret
fingerprint: AA:BB:...
apps: com.some.app,com.other.app
''');

if (!await vpn.hasVpnPermission()) {
  await vpn.requestVpnPermission();
}
await vpn.connect('home');

vpn.watchStatus().listen((status) => print(status.state));
```

See [`tunnel_config.dart`](lib/src/models/tunnel_config.dart) for the config shape and [`vpn_repository.dart`](lib/src/vpn_repository.dart) for the full API (list/rename/delete configs, per-app allow-list, ad-block toggle, logs, battery-optimization exemption).

## How it works

The Dart API talks to a native `TunnelVpnService` over a Flutter method/event channel. The service owns a TUN interface and relays raw IP packets to `detour-server` over a certificate-pinned TLS connection (see the top-level README for the wire protocol). Split-tunneling is just `VpnService.Builder.addAllowedApplication` for the packages in a config's `apps` list.
