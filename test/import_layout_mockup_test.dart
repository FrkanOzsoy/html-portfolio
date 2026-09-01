import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:barkod_tarayici/widgets/import_layout_mockup.dart';

void main() {
  testWidgets('both layout mockups paint without error', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(width: 160, child: ImportLayoutMockup.normal()),
              SizedBox(width: 160, child: ImportLayoutMockup.catalog()),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(ImportLayoutMockup), findsNWidgets(2));
  });
}
