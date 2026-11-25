import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

/// Answers the plugin's channels from plain fields.
class FakeVpn {
  FakeVpn(WidgetTester tester) : _messenger = tester.binding.defaultBinaryMessenger {
    _messenger.setMockMethodCallHandler(const MethodChannel('detour_vpn/vpn'), _answer);
    _messenger.setMockMethodCallHandler(const MethodChannel('detour_vpn/vpn/state'), (_) async => null);
    _messenger.setMockMethodCallHandler(const MethodChannel('installed_apps'), (call) async => switch (call.method) {
          'getInstalledApps' => [_app('Chrome', 'com.android.chrome'), _app('Arabic قناة', 'ar')],
          'getAppInfo' => _app('Chrome', 'com.android.chrome'),
          _ => null,
        });
  }

  final TestDefaultBinaryMessenger _messenger;
  final calls = <MethodCall>[];
  List<(String, List<String>)> configs = [
    ('aws', ['com.android.chrome']),
  ];
  Set<String> adminOf = {'aws'};
  String? last;
  String state = 'DOWN';
  bool exempt = true;
  bool usageAccess = false;
  String idleAction = 'off';
  int idleMinutes = 5;
  int usageRequests = 0;
  List<Map<String, Object>> users = [];

  Iterable<Object?> argsOf(String method) => calls.where((c) => c.method == method).map((c) => c.arguments);

  static Map<String, Object?> _app(String name, String package) => {
        'name': name,
        'package_name': package,
        'icon': null,
        'version_name': '1',
        'version_code': 1,
        'platform_type': 'flutter',
        'installed_timestamp': 0,
        'is_system_app': false,
        'is_launchable_app': true,
        'category': -1,
      };

  Future<Object?> _answer(MethodCall call) async {
    calls.add(call);
    final args = call.arguments as Map? ?? const {};
    switch (call.method) {
      case 'listConfigs':
        return [
          for (final (name, apps) in configs)
            {'name': name, 'includedApplications': apps, 'endpointHost': '203.0.113.7', 'endpointPort': 443},
        ];
      case 'deleteConfig':
        configs.removeWhere((c) => c.$1 == args['name']);
      case 'getLastConfig':
        return last;
      case 'getState':
        return {'state': state, 'name': state == 'DOWN' ? null : configs.first.$1, 'stats': null};
      case 'hasVpnPermission' || 'requestNotificationPermission':
        return true;
      case 'hasBatteryExemption':
        return exempt;
      case 'hasUsageAccess':
        return usageAccess;
      case 'requestUsageAccess':
        usageRequests++;
      case 'getIdleAction':
        return usageAccess ? idleAction : 'off';
      case 'setIdleAction':
        idleAction = args['action'] as String;
      case 'getIdleMinutes':
        return idleMinutes;
      case 'setIdleMinutes':
        idleMinutes = args['minutes'] as int;
      case 'getVpnLogs':
        return [
          {'timestamp': '2026-11-25T19:00:00', 'message': 'Connected to aws'},
        ];
      case 'adminRequest':
        if (!adminOf.contains(args['name'])) throw PlatformException(code: 'admin_failed', message: 'no');
        return {'users': users, 'config': null};
      case 'previewConfig':
        return {'name': 'aws', 'endpointHost': '1.2.3.4', 'endpointPort': 443, 'username': 'ali'};
      case 'importConfig':
        configs = [...configs, (args['name'] as String, <String>[])];
    }
    return null;
  }

  static Map<String, Object> user(
    String name, {
    bool admin = false,
    bool invite = false,
    int connected = 0,
    int kbps = 0,
    int quota = 0,
    int used = 0,
  }) =>
      {
        'username': name,
        'admin': admin,
        'invite': invite,
        'connected': connected,
        'speedKbps': kbps,
        'quotaBytes': quota,
        'usedBytes': used,
      };
}

Widget app(Widget home, {ThemeData? theme, double textScale = 1}) => MaterialApp(
      theme: theme,
      debugShowCheckedModeBanner: false,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale), disableAnimations: true),
        child: child!,
      ),
      home: home,
    );
