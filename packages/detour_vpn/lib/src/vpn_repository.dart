import 'package:flutter/services.dart';

import 'vpn_channel.dart';
import 'models/idle_action.dart';
import 'models/server_user.dart';
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

  /// Lets the connection notification show, on Android versions that ask.
  Future<bool> requestNotificationPermission() => _channel.requestNotificationPermission();

  /// Saves a config, encrypted on this device. An invite link is claimed on its
  /// server first, so it needs a connection and works only once.
  Future<void> importConfig({required String name, required String text}) async {
    try {
      await _channel.importConfig(name: name, text: text);
    } on PlatformException catch (e) {
      throw VpnRepositoryException(e.message ?? 'Failed to import config');
    }
  }

  /// Checks a link or config text without saving it. The name is a suggestion
  /// and may be empty.
  Future<TunnelConfig> previewConfig(String text) async {
    try {
      return TunnelConfig.fromMap(await _channel.previewConfig(text));
    } on PlatformException catch (e) {
      throw VpnRepositoryException(e.message ?? 'Invalid config');
    }
  }

  Future<List<TunnelConfig>> listConfigs() async {
    final raw = await _channel.listConfigs();
    return raw.map(TunnelConfig.fromMap).toList();
  }

  Future<void> deleteConfig(String name) => _channel.deleteConfig(name);

  Future<void> renameConfig(String oldName, String newName) async {
    try {
      await _channel.renameConfig(oldName, newName);
    } on PlatformException catch (e) {
      throw VpnRepositoryException(e.message ?? 'Failed to rename');
    }
  }

  Future<void> setIncludedApps(String name, List<String> packages) =>
      _channel.setIncludedApps(name, packages);

  /// Whether the saved config [name]'s user is an admin of its server, or null
  /// if the server can't be reached. The server checks every request anyway.
  Future<bool?> isServerAdmin(String name) async {
    try {
      await _channel.adminRequest(name, 'list');
      return true;
    } on PlatformException catch (e) {
      return e.code == 'admin_failed' ? false : null;
    }
  }

  /// Users of the server behind the saved config [name]. Like the other admin
  /// calls, throws [VpnRepositoryException] unless that config's user is an admin.
  Future<List<ServerUser>> listServerUsers(String name) async {
    final reply = await _admin(name, 'list');
    return (reply['users'] as List).cast<Map<dynamic, dynamic>>().map(ServerUser.fromMap).toList();
  }

  /// Creates a user and returns a link for them to import.
  Future<String> addServerUser(String name, String username) async =>
      (await _admin(name, 'add', username))['config'] as String;

  /// Disconnects the user, changes their password and returns a new link.
  Future<String> resetServerUser(String name, String username) async =>
      (await _admin(name, 'reset', username))['config'] as String;

  /// Removes the user and disconnects them right away.
  Future<void> removeServerUser(String name, String username) => _admin(name, 'remove', username);

  /// Sets the user's limits, effective right away. 0 means unlimited.
  Future<void> setServerUserLimits(
    String name,
    String username, {
    required int speedKbps,
    required int quotaBytes,
  }) =>
      _admin(name, 'setlimits', username, speedKbps, quotaBytes);

  /// Starts counting the user's data usage from zero again.
  Future<void> resetServerUserUsage(String name, String username) => _admin(name, 'resetusage', username);

  Future<Map<dynamic, dynamic>> _admin(
    String name,
    String op, [
    String? username,
    int speedKbps = 0,
    int quotaBytes = 0,
  ]) async {
    try {
      return await _channel.adminRequest(
        name,
        op,
        username: username,
        speedKbps: speedKbps,
        quotaBytes: quotaBytes,
      );
    } on PlatformException catch (e) {
      throw VpnRepositoryException(e.message ?? 'Request failed');
    }
  }

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

  /// What happens after [getIdleMinutes] without this app or any tunneled app
  /// on screen, or steady traffic. [IdleAction.off] without usage access.
  Future<IdleAction> getIdleAction() async => IdleAction.values.byName(await _channel.getIdleAction());

  Future<void> setIdleAction(IdleAction action) => _channel.setIdleAction(action.name);

  Future<int> getIdleMinutes() => _channel.getIdleMinutes();

  /// From 1 to 1440.
  Future<void> setIdleMinutes(int minutes) => _channel.setIdleMinutes(minutes);

  /// Needed to see which app is on screen.
  Future<bool> hasUsageAccess() => _channel.hasUsageAccess();

  /// Opens the system screen where the user can grant usage access.
  Future<void> requestUsageAccess() => _channel.requestUsageAccess();

  Future<bool> hasBatteryExemption() => _channel.hasBatteryExemption();

  Future<void> requestBatteryExemption() => _channel.requestBatteryExemption();
}

class VpnRepositoryException implements Exception {
  VpnRepositoryException(this.message);
  final String message;

  @override
  String toString() => message;
}
