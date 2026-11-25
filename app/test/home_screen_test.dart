import 'package:detour/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('only servers that confirm admin show Manage users', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('detour_vpn/vpn/state'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('detour_vpn/vpn'), (call) async {
      switch (call.method) {
        case 'listConfigs':
          return [
            for (final n in ['mine', 'other', 'down'])
              {'name': n, 'includedApplications': <String>[], 'endpointHost': 'h', 'endpointPort': 443},
          ];
        case 'hasBatteryExemption':
          return false;
        case 'adminRequest':
          final name = (call.arguments as Map)['name'];
          if (name == 'mine') return {'users': <Object>[], 'config': null};
          throw PlatformException(code: name == 'other' ? 'admin_failed' : 'unreachable');
      }
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();

    expect(find.textContaining('save battery'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('save battery'), findsNothing);

    for (final (i, visible) in [true, false, false].indexed) {
      await tester.tap(find.byType(PopupMenuButton<String>).at(i));
      await tester.pumpAndSettle();
      expect(find.text('Select apps'), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Check latency'), findsOneWidget);
      expect(find.text('Manage users'), visible ? findsOneWidget : findsNothing);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
    }
  });
}
