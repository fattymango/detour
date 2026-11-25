import 'package:detour/home_screen.dart';
import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('stop when not in use asks for usage access, then turns on', (tester) async {
    var access = false;
    var action = 'off';
    var opened = 0;
    var minutes = 5;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('detour_vpn/vpn/state'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('detour_vpn/vpn'), (call) async {
      switch (call.method) {
        case 'listConfigs':
          return <Object>[];
        case 'hasBatteryExemption':
          return true;
        case 'hasUsageAccess':
          return access;
        case 'requestUsageAccess':
          opened++;
        case 'getIdleAction':
          return access ? action : 'off';
        case 'getIdleMinutes':
          return minutes;
        case 'setIdleMinutes':
          minutes = (call.arguments as Map)['minutes'] as int;
        case 'setIdleAction':
          action = (call.arguments as Map)['action'] as String;
      }
      return null;
    });
    final dropdown = find.byType(DropdownButton<IdleAction>);
    IdleAction? shown() => tester.widget<DropdownButton<IdleAction>>(dropdown).value;
    Future<void> choose(String label) async {
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    Future<void> resume() async {
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    expect(shown(), IdleAction.off);
    expect(find.text('After'), findsNothing);

    await choose('Standby');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect((opened, action), (0, 'off'));

    await choose('Standby');
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    await resume();
    expect((opened, action, shown()), (1, 'off', IdleAction.off));

    access = true;
    await resume();
    expect((action, shown()), ('standby', IdleAction.standby));

    for (final bad in ['0', '1441', '2.5', 'x', '']) {
      await tester.tap(find.text('After'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), bad);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('whole number'), findsOneWidget, reason: bad);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('After'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '٢٠');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((minutes, find.text('20 minutes').evaluate().length), (20, 1));
    await tester.tap(find.text('After'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, '30'));
    await tester.pumpAndSettle();
    expect(minutes, 30);

    await choose('Turn off');
    expect((action, shown()), ('stop', IdleAction.stop));
    await choose('Stay on');
    expect((action, shown()), ('off', IdleAction.off));
    expect(tester.takeException(), isNull);
  });
}
