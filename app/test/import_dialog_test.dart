import 'package:detour/import_dialog.dart';
import 'package:detour/invite_sheet.dart';
import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('long paste with the keyboard open fits, and errors keep the text', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    tester.view.viewInsets = const FakeViewPadding(bottom: 1200);
    addTearDown(tester.view.reset);

    var fail = true;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('detour_vpn/vpn'),
      (call) async => fail
          ? throw PlatformException(code: 'bad_config', message: 'Broken config')
          : call.method == 'previewConfig'
              ? {'name': 'aws', 'endpointHost': '1.2.3.4', 'endpointPort': 443, 'username': 'ali'}
              : null,
    );
    final result = <bool?>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result.add(await showDialog<bool>(
            context: context,
            builder: (_) => ImportDialog(vpn: VpnRepository(), existingNames: const {'aws'}),
          )),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final linkField = find.byType(TextField).first;
    final nameField = find.byType(TextField).last;
    final pasted = 'host: 1.2.3.4\n' * 40;
    await tester.enterText(nameField, 'aws');
    await tester.enterText(linkField, pasted);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.textContaining('already have'), findsOneWidget);

    await tester.enterText(nameField, 'new');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Broken config'), findsOneWidget);
    expect(find.text(pasted), findsOneWidget);
    expect(tester.takeException(), isNull);

    fail = false;
    await tester.enterText(nameField, '');
    await tester.enterText(linkField, 'detour://link');
    await tester.pumpAndSettle();
    expect(find.text('1.2.3.4:443'), findsOneWidget);
    expect(find.text('aws 2'), findsOneWidget);
    await tester.ensureVisible(find.text('Add'));
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(result, [true]);
  });

  testWidgets('invite sheet fits a small screen and copies the link', (tester) async {
    tester.view.physicalSize = const Size(640, 900);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    final link = 'detour://ali:pw@1.2.3.4:443/${'ab' * 32}?name=aws';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: InviteSheet(username: 'ali', server: 'aws', link: link)),
    ));
    await tester.tap(find.text(link));
    await tester.pump();
    expect(copied, link);
    expect(find.text('Copied'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
