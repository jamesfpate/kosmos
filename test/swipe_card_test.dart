// The swipe card's gestures: one finger swipes (keep / delete), two fingers zoom without swiping.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:winnow/state.dart';
import 'package:winnow/ui/cull.dart';

void main() {
  Future<List<Dir>> pump(WidgetTester tester) async {
    final swipes = <Dir>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 600,
            child: SwipeCard(
              cardId: 'a',
              onSwipe: (dir, fx) async => swipes.add(dir),
              child: const ColoredBox(color: Colors.teal, key: Key('photo')),
            ),
          ),
        ),
      ),
    ));
    return swipes;
  }

  testWidgets('a one-finger swipe right keeps, left deletes', (tester) async {
    final swipes = await pump(tester);
    await tester.drag(find.byKey(const Key('photo')), const Offset(260, 0));
    await tester.pumpAndSettle();
    expect(swipes, [Dir.right]);
  });

  testWidgets('a two-finger pinch zooms and never swipes', (tester) async {
    final swipes = await pump(tester);
    final c = tester.getCenter(find.byKey(const Key('photo')));
    final a = await tester.startGesture(c - const Offset(40, 0), pointer: 1);
    final b = await tester.startGesture(c + const Offset(40, 0), pointer: 2);
    for (var i = 1; i <= 10; i++) {
      await a.moveTo(c - Offset(40.0 + i * 12, 0));
      await b.moveTo(c + Offset(40.0 + i * 12, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Zoomed in while the fingers are down.
    final zoomed = tester.widgetList<Transform>(find.descendant(of: find.byType(SwipeCard), matching: find.byType(Transform)))
        .any((t) => t.transform.getMaxScaleOnAxis() > 1.5);
    expect(zoomed, isTrue);
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(swipes, isEmpty);
  });
}
