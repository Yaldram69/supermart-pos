import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermart_pos/theme.dart';
import 'package:supermart_pos/widgets/command_palette.dart';
import 'package:supermart_pos/widgets/pin_pad.dart';

/// The pad with its submit button is taller than the default 800x600 test view,
/// so the tests give it room (a real till window is at least 1100x700).
void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1100);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  group('PIN pad', () {
    testWidgets('submit stays disabled until four digits are entered', (tester) async {
      _tallView(tester);
      String? submitted;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: PinPad(onSubmit: (p) => submitted = p)),
      ));

      FilledButton button() => tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button().onPressed, isNull);

      for (final d in ['1', '2', '3']) {
        await tester.tap(find.text(d));
      }
      await tester.pump();
      expect(button().onPressed, isNull, reason: 'three digits is not enough');

      await tester.tap(find.text('4'));
      await tester.pump();
      expect(button().onPressed, isNotNull);

      await tester.tap(find.byType(FilledButton));
      expect(submitted, '1234');
    });

    testWidgets('backspace removes the last digit and clear empties it', (tester) async {
      _tallView(tester);
      String? submitted;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: PinPad(onSubmit: (p) => submitted = p)),
      ));

      for (final d in ['9', '8', '7', '6', '5']) {
        await tester.tap(find.text(d));
      }
      await tester.tap(find.byIcon(Icons.backspace_outlined));
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      expect(submitted, '9876');

      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    });

    testWidgets('no more than eight digits are accepted', (tester) async {
      _tallView(tester);
      String? submitted;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: PinPad(onSubmit: (p) => submitted = p)),
      ));
      for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await tester.tap(find.byType(FilledButton));
      expect(submitted, '12345678');
    });
  });

  group('command palette', () {
    testWidgets('typing narrows the list and Enter runs the top result', (tester) async {
      var ran = '';
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showCommandPalette(context, [
                PaletteItem(title: 'Billing', icon: Icons.point_of_sale, keywords: 'sale till', onRun: () => ran = 'billing'),
                PaletteItem(title: 'Invoices', icon: Icons.receipt_long, onRun: () => ran = 'invoices'),
                PaletteItem(title: 'Sign out', icon: Icons.logout, group: 'Actions', onRun: () => ran = 'signout'),
              ]),
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Invoices'), findsOneWidget);

      // a keyword ("till") finds Billing even though the title does not contain it
      await tester.enterText(find.byType(TextField), 'till');
      await tester.pumpAndSettle();
      expect(find.text('Invoices'), findsNothing);
      expect(find.text('Billing'), findsOneWidget);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(ran, 'billing');
    });

    testWidgets('a query with no match says so', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showCommandPalette(context, [
                PaletteItem(title: 'Billing', icon: Icons.point_of_sale, onRun: () {}),
              ]),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing matches'), findsOneWidget);
    });
  });
}
