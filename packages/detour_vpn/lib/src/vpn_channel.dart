import 'package:flutter/services.dart';

/// Thin wrapper around the native VPN MethodChannel/EventChannel.
/// Keeps every raw channel name/method name in one place so the rest of the
/// app never talks to `MethodChannel`/`EventChannel` directly.
class VpnChannel {
  VpnChannel()
      : _methodChannel = const MethodChannel('detour_vpn/vpn'),
        _eventChannel = const EventChannel('detour_vpn/vpn/state');

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  Stream<Map<dynamic, dynamic>>? _stateStream;

  Stream<Map<dynamic, dynamic>> get stateChanges {
    return _stateStream ??= _eventChannel
        .receiveBroadcastStream()
        .map((event) => event as Map<dynamic, dynamic>);
  }

  Future<bool> hasVpnPermission() async {
    return await _methodChannel.invokeMethod<bool>('hasVpnPermission') ?? false;
  }

  Future<bool> requestVpnPermission() async {
    return await _methodChannel.invokeMethod<bool>('requestVpnPermission') ?? false;
  }

  Future<void> importConfig({required String name, required String text}) {
    return _methodChannel.invokeMethod('importConfig', {'name': name, 'text': text});
  }

  Future<List<Map<dynamic, dynamic>>> listConfigs() async {
    final result = await _methodChannel.invokeMethod<List<dynamic>>('listConfigs');
    return (result ?? const []).cast<Map<dynamic, dynamic>>();
  }

  Future<void> deleteConfig(String name) {
    return _methodChannel.invokeMethod('deleteConfig', {'name': name});
  }

  Future<void> renameConfig(String oldName, String newName) {
    return _methodChannel.invokeMethod('renameConfig', {'oldName': oldName, 'newName': newName});
  }

  Future<void> setIncludedApps(String name, List<String> packages) {
    return _methodChannel.invokeMethod('setIncludedApps', {
      'name': name,
      'packages': packages,
    });
  }

  Future<void> connect(String name) {
    return _methodChannel.invokeMethod('connect', {'name': name});
  }

  Future<void> disconnect() {
    return _methodChannel.invokeMethod('disconnect');
  }

  Future<Map<dynamic, dynamic>?> getState() async {
    return await _methodChannel.invokeMethod<Map<dynamic, dynamic>>('getState');
  }

  Future<List<Map<dynamic, dynamic>>> getVpnLogs() async {
    final result = await _methodChannel.invokeMethod<List<dynamic>>('getVpnLogs');
    return (result ?? const []).cast<Map<dynamic, dynamic>>();
  }

  Future<bool> hasBatteryExemption() async {
    return await _methodChannel.invokeMethod<bool>('hasBatteryExemption') ?? false;
  }

  Future<void> requestBatteryExemption() {
    return _methodChannel.invokeMethod('requestBatteryExemption');
  }

  Future<bool> isAdBlockEnabled() async {
    return await _methodChannel.invokeMethod<bool>('isAdBlockEnabled') ?? true;
  }

  Future<void> setAdBlockEnabled(bool enabled) {
    return _methodChannel.invokeMethod('setAdBlockEnabled', {'enabled': enabled});
  }

  Future<int> getAdBlockedCount() async {
    return await _methodChannel.invokeMethod<int>('getAdBlockedCount') ?? 0;
  }

  Future<List<Map<dynamic, dynamic>>> getAdBlockedDomains() async {
    final result = await _methodChannel.invokeMethod<List<dynamic>>('getAdBlockedDomains');
    return (result ?? const []).cast<Map<dynamic, dynamic>>();
  }
}
