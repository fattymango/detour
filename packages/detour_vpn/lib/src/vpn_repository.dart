import 'package:flutter/services.dart';

import 'vpn_channel.dart';
import 'models/ad_blocked_domain.dart';
import 'models/tunnel_config.dart';
import 'models/tunnel_status.dart';
import 'models/vpn_log_entry.dart';

/// Domain-facing API for the VPN feature. Blocs depend on this, never on
/// [VpnChannel] directly, so the platform-channel plumbing stays swappable.
class VpnRepository {
  VpnRepository({VpnChannel? channel}) : _channel = channel ?? VpnChannel();

  final VpnChannel _channel;

  Stream<TunnelStatus> watchStatus() {
    return _channel.stateChanges.map(TunnelStatus.fromEvent);
  }

  Future<TunnelStatus> currentStatus() async {
    final state = await _channel.getState();
    if (state == null) return const TunnelStatus.initial();
    return TunnelStatus.fromEvent(state);
  }

  Future<bool> hasVpnPermission() => _channel.hasVpnPermission();

  Future<bool> requestVpnPermission() => _channel.requestVpnPermission();

  Future<void> importConfig({required String name, required String text}) async {
    try {
      await _channel.importConfig(name: name, text: text);
    } on PlatformException catch (e) {
      throw VpnRepositoryException(e.message ?? 'Failed to import config');
    }
  }

  Future<List<TunnelConfig>> listConfigs() async {
    final raw = await _channel.listConfigs();
    return raw.map(TunnelConfig.fromMap).toList();
  }

  Future<void> deleteConfig(String name) => _channel.deleteConfig(name);

  Future<void> renameConfig(String oldName, String newName) =>
      _channel.renameConfig(oldName, newName);

  Future<void> setIncludedApps(String name, List<String> packages) =>
      _channel.setIncludedApps(name, packages);

  Future<void> connect(String name) async {
    try {
      await _channel.connect(name);
    } on PlatformException catch (e) {
      throw VpnRepositoryException(e.message ?? 'Failed to connect');
    }
  }

  Future<void> disconnect() => _channel.disconnect();

  Future<List<VpnLogEntry>> getLogs() async {
    final raw = await _channel.getVpnLogs();
    return raw.map(VpnLogEntry.fromMap).toList();
  }

  Future<bool> hasBatteryExemption() => _channel.hasBatteryExemption();

  Future<void> requestBatteryExemption() => _channel.requestBatteryExemption();

  Future<bool> isAdBlockEnabled() => _channel.isAdBlockEnabled();

  Future<void> setAdBlockEnabled(bool enabled) => _channel.setAdBlockEnabled(enabled);

  Future<int> getAdBlockedCount() => _channel.getAdBlockedCount();

  Future<List<AdBlockedDomain>> getAdBlockedDomains() async {
    final raw = await _channel.getAdBlockedDomains();
    return raw.map(AdBlockedDomain.fromMap).toList();
  }
}

class VpnRepositoryException implements Exception {
  VpnRepositoryException(this.message);
  final String message;

  @override
  String toString() => message;
}
