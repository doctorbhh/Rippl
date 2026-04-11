// Basic Flutter test for Rippl app

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rippl/main.dart';

void main() {
  testWidgets('App launches without crashing', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const ProviderScope(child: RipplApp()));

    // Verify the app name is displayed
    expect(find.text('Rippl'), findsOneWidget);
  });
}
