import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:barkod_tarayici/app_settings.dart';
import 'package:barkod_tarayici/widgets/sortable_table.dart';
import 'package:barkod_tarayici/widgets/table_pager.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget boxed(Widget child) => MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 900, height: 500, child: child),
        ),
      );

  testWidgets('SortableTable paginates and the pager switches pages', (tester) async {
    final rows = List.generate(250, (i) => i);
    await tester.pumpWidget(boxed(
      SortableTable<int>(
        rows: rows,
        pageSize: 100,
        columns: [
          SortColumn<int>(label: 'N', sortKey: (r) => r, cell: (r) => Text('row-$r')),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    // page 1
    expect(find.text('row-0'), findsOneWidget); // top row of page 1
    expect(find.text('1–100 / 250'), findsOneWidget);

    // jump to the last page via its number chip
    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();
    expect(find.text('row-0'), findsNothing); // page 1 no longer mounted
    expect(find.text('row-200'), findsOneWidget); // top row of page 3
    expect(find.text('201–250 / 250'), findsOneWidget);

    // step back one page with the arrow
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text('row-100'), findsOneWidget);
    expect(find.text('101–200 / 250'), findsOneWidget);
  });

  testWidgets('under the page size there is no pager', (tester) async {
    await tester.pumpWidget(boxed(
      SortableTable<int>(
        rows: List.generate(30, (i) => i),
        pageSize: 100,
        columns: [
          SortColumn<int>(label: 'N', sortKey: (r) => r, cell: (r) => Text('row-$r')),
        ],
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(TablePager), findsNothing);
    expect(find.text('row-0'), findsOneWidget);
  });

  testWidgets('changing page size persists to appSettings', (tester) async {
    await appSettings.load();
    await tester.pumpWidget(boxed(
      TablePager(
        totalItems: 500,
        pageIndex: 0,
        pageSize: 100,
        onPageChanged: (_) {},
        onPageSizeChanged: (_) {},
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('100').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('200').last);
    await tester.pumpAndSettle();

    expect(appSettings.tablePageSize, 200);
  });
}
