/// Dart API for the Detour split-tunnel VPN: connect/disconnect, manage
/// saved server profiles, per-app tunneling, and the built-in ad blocker.
/// Backed by a native Android `VpnService` (see the plugin's `android/`
/// folder) talking the detour-server TLS protocol.
library detour_vpn;

export 'src/vpn_repository.dart';
export 'src/models/tunnel_config.dart';
export 'src/models/tunnel_status.dart';
export 'src/models/vpn_log_entry.dart';
export 'src/models/ad_blocked_domain.dart';
