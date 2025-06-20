//import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_view/main.dart';

void main() {
  testWidgets('MyApp renders LocationScreen widget', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(MyApp());
    // Checks that the location text starts with "Fetching..."
    expect(find.textContaining('Fetching'), findsOneWidget);
  });
}
