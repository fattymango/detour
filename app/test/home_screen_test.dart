import 'package:detour/home_screen.dart';
import 'package:detour/power_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_vpn.dart';

void main() {
  testWidgets('connects to the last used server', (tester) async {
    final vpn = FakeVpn(tester)
      ..configs = [('aws', ['com.android.chrome']), ('meow', [])]
      ..last = 'meow'
      ..exempt = false;
    await tester.pumpWidget(app(const HomeScreen()));
    await tester.pumpAndSettle();
    expect(find.text('meow'), findsOneWidget);
    expect(find.text('All apps'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);

    expect(find.textContaining('save battery'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('save battery'), findsNothing);

    await tester.tap(find.byType(PowerButton));
    await tester.pumpAndSettle();
    expect(vpn.argsOf('connect'), [
      {'name': 'meow'},
    ]);
  });

  for (final (state, title, action) in [
    ('UP', 'Connected', 'Disconnect'),
    ('CONNECTING', 'Connecting…', 'Cancel'),
    ('RECONNECTING', 'Reconnecting…', 'Cancel'),
    ('STANDBY', 'On standby', 'Turn off'),
  ]) {
    testWidgets('$state shows "$title" and tapping turns it off', (tester) async {
      final vpn = FakeVpn(tester)..state = state;
      await tester.pumpWidget(app(const HomeScreen()));
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(find.bySemanticsLabel(action), findsOneWidget);
      await tester.tap(find.byType(PowerButton));
      await tester.pumpAndSettle();
      expect(vpn.argsOf('disconnect'), hasLength(1));
      expect(vpn.argsOf('connect'), isEmpty);
    });
  }

  testWidgets('a failure says why and offers another try', (tester) async {
    final vpn = FakeVpn(tester)..state = 'ERROR:Data limit reached';
    await tester.pumpWidget(app(const HomeScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Data limit reached'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Try again'));
    await tester.pumpAndSettle();
    expect(vpn.argsOf('connect'), hasLength(1));
  });

  testWidgets('with no servers it asks for an invite', (tester) async {
    final vpn = FakeVpn(tester)..configs = [];
    await tester.pumpWidget(app(const HomeScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste invite link'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'detour://x');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(vpn.argsOf('importConfig'), hasLength(1));
    expect(find.byType(PowerButton), findsOneWidget);
  });
}
