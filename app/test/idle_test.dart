import 'package:detour/idle_screen.dart';
import 'package:detour/theme.dart';
import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_vpn.dart';

void main() {
  testWidgets('stop when not in use asks for usage access, then turns on', (tester) async {
    final vpn = FakeVpn(tester);
    String? shown() => {
          for (final c in tester.widgetList<InfoCard>(find.byType(InfoCard)))
            if (c.selected) c.title,
        }.single;
    Future<void> choose(String label) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    Future<void> resume() async {
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(app(IdleScreen(vpn: VpnRepository())));
    await tester.pumpAndSettle();
    expect(shown(), 'Stay connected');
    expect(find.text('After'), findsNothing);

    await choose('Standby');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect((vpn.usageRequests, vpn.idleAction), (0, 'off'));

    await choose('Standby');
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    await resume();
    expect((vpn.usageRequests, vpn.idleAction, shown()), (1, 'off', 'Stay connected'));

    vpn.usageAccess = true;
    await resume();
    expect((vpn.idleAction, shown()), ('standby', 'Standby'));

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
    expect((vpn.idleMinutes, find.text('20 minutes').evaluate().length), (20, 1));
    await tester.tap(find.text('After'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, '30'));
    await tester.pumpAndSettle();
    expect(vpn.idleMinutes, 30);

    await choose('Turn off');
    expect((vpn.idleAction, shown()), ('stop', 'Turn off'));
    await choose('Stay connected');
    expect((vpn.idleAction, shown()), ('off', 'Stay connected'));
    expect(tester.takeException(), isNull);
  });
}
