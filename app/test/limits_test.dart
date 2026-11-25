import 'package:detour/limits_dialog.dart';
import 'package:detour/users_screen.dart';
import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses amounts', () {
    expect(parseAmount(''), 0);
    expect(parseAmount(' 1.5 '), 1.5);
    expect(parseAmount('1,5'), 1.5);
    expect(parseAmount('١٠٫٥'), 10.5);
    for (final bad in ['x', '-1', '1.2.3', '.', '1e9', '9999999']) {
      expect(parseAmount(bad), isNull, reason: bad);
    }
  });

  test('formats amounts', () {
    expect(formatBytes(0), '0 MB');
    expect(formatBytes(1500000), '1.5 MB');
    expect(formatBytes(10000000000), '10 GB');
    expect(formatNumber(100), '100');
  });

  testWidgets('admin sees usage and sets limits', (tester) async {
    final calls = <Map<dynamic, dynamic>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('detour_vpn/vpn'),
      (call) async {
        calls.add(call.arguments as Map);
        return {
          'users': [
            {
              'username': 'ali',
              'admin': false,
              'connected': 1,
              'speedKbps': 10000,
              'quotaBytes': 5000000000,
              'usedBytes': 1200000000,
            },
          ],
          'config': null,
        };
      },
    );
    await tester.pumpWidget(MaterialApp(
      home: UsersScreen(
        vpn: VpnRepository(),
        config: const TunnelConfig(name: 'aws', includedApplications: []),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('1.2 GB of 5 GB · max 10 Mbps'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Limits'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '0.01');
    await tester.enterText(find.byType(TextField).last, 'x');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter'), findsNWidgets(2));

    await tester.enterText(find.byType(TextField).first, '2.5');
    await tester.enterText(find.byType(TextField).last, '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final sent = calls.singleWhere((c) => c['op'] == 'setlimits');
    expect((sent['username'], sent['speedKbps'], sent['quotaBytes']), ('ali', 2500, 0));
    expect(tester.takeException(), isNull);
  });
}
