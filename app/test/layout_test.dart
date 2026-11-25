import 'package:detour/app_selector_screen.dart';
import 'package:detour/home_screen.dart';
import 'package:detour/idle_screen.dart';
import 'package:detour/logs_screen.dart';
import 'package:detour/servers_screen.dart';
import 'package:detour/settings_screen.dart';
import 'package:detour/theme.dart';
import 'package:detour/users_screen.dart';
import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_vpn.dart';

void main() {
  final repo = VpnRepository();
  const config = TunnelConfig(name: 'a server with a rather long name', includedApplications: ['com.android.chrome']);
  final screens = <String, Widget Function()>{
    'home': () => const HomeScreen(),
    'servers': () => ServersScreen(vpn: repo, selected: 'aws', inUse: null, latency: (_) async => 42),
    'people': () => UsersScreen(vpn: repo, config: config),
    'idle': () => IdleScreen(vpn: repo),
    'apps': () => AppSelectorScreen(vpn: repo, config: config),
    'settings': () => SettingsScreen(vpn: repo),
    'log': () => LogsScreen(vpn: repo),
  };

  for (final MapEntry(key: name, value: build) in screens.entries) {
    for (final (size, scale) in [(const Size(320, 568), 2.0), (const Size(320, 568), 1.0), (const Size(640, 320), 1.3)]) {
      for (final brightness in Brightness.values) {
        testWidgets('$name fits $size at ${scale}x, ${brightness.name}', (tester) async {
          tester.view
            ..physicalSize = size
            ..devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          FakeVpn(tester)
            ..exempt = false
            ..usageAccess = true
            ..idleAction = 'standby'
            ..state = 'RECONNECTING'
            ..adminOf = {'aws', config.name}
            ..users = [
              FakeVpn.user('phone', admin: true),
              FakeVpn.user('a-user-name-of-thirty-two-chars-', connected: 3, kbps: 10000, quota: 5000000000, used: 6000000000),
              FakeVpn.user('x', invite: true),
            ];
          await tester.pumpWidget(app(build(), theme: detourTheme(brightness), textScale: scale));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (name == 'apps') expect(find.text('Chrome'), findsOneWidget);
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        });
      }
    }
  }
}
