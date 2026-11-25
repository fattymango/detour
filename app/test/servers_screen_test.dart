import 'package:detour/servers_screen.dart';
import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_vpn.dart';

void main() {
  late FakeVpn vpn;
  String? picked;

  Future<void> open(WidgetTester tester, {String? inUse}) async {
    vpn = FakeVpn(tester)..configs = [('mine', []), ('other', []), ('down', [])];
    vpn.adminOf = {'mine'};
    picked = null;
    await tester.pumpWidget(app(Builder(
      builder: (context) => TextButton(
        onPressed: () async => picked = await Navigator.push<String>(
          context,
          MaterialPageRoute(
            builder: (_) => ServersScreen(
              vpn: VpnRepository(),
              selected: 'mine',
              inUse: inUse,
              latency: (c) async => c.name == 'down' ? null : 42,
            ),
          ),
        ),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows latency, and people only where you are admin', (tester) async {
    await open(tester);
    expect(find.text('42 ms · Admin'), findsOneWidget);
    expect(find.text('42 ms'), findsOneWidget);
    expect(find.text("Can't be reached"), findsOneWidget);
    expect(find.byTooltip('Manage people'), findsOneWidget);
    await tester.tap(find.text('other'));
    await tester.pumpAndSettle();
    expect(picked, 'other');
  });

  testWidgets('deleting asks first', (tester) async {
    await open(tester);
    for (final (button, left) in [('Cancel', 3), ('Delete', 2)]) {
      await tester.tap(find.byType(PopupMenuButton<String>).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      expect(vpn.configs, hasLength(left));
    }
    expect(find.text('other'), findsNothing);
  });

  testWidgets('the server in use cannot be renamed or deleted', (tester) async {
    await open(tester, inUse: 'mine');
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Disconnect first'), findsOneWidget);
    final items = tester.widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>));
    expect(items.map((i) => i.enabled), everyElement(isFalse));
  });
}
