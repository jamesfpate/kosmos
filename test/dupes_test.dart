// Duplicate grouping: exact copies always group; similar shots only when taken close together.

import 'package:flutter_test/flutter_test.dart';
import 'package:winnow/dupes.dart';
import 'package:winnow/models.dart';

void main() {
  const minute = 60 * 1000;
  Item photo(String name, int at, {int w = 4000}) => Item.file('/p/$name', taken: at, bucket: 'p', width: w, height: 3000);

  test('exact copies group, the biggest kept first, whenever they were taken', () {
    final a = photo('a.jpg', 0), b = photo('b.jpg', 600 * minute, w: 2000);
    final g = groupDuplicates({a: const Prints('10:x', null, 10), b: const Prints('10:x', null, 10)});
    expect(g.length, 1);
    expect(g.first.exact, isTrue);
    expect(g.first.items.first, a);
  });

  test('similar shots group only within the time window', () {
    const h = 0x0F0F0F0F0F0F0F0F;
    final a = photo('a.jpg', 0), b = photo('b.jpg', 2 * minute), c = photo('c.jpg', 60 * minute);
    final g = groupDuplicates({
      a: const Prints('1:a', h, 1),
      b: const Prints('2:b', h ^ 0x3, 2), // 2 bits apart, 2 minutes later: similar
      c: const Prints('3:c', h, 3), // identical picture, but an hour later: not grouped
    });
    expect(g.length, 1);
    expect({for (final i in g.first.items) i.id}, {a.id, b.id});
    expect(g.first.exact, isFalse);
  });

  test('different pictures taken together stay apart', () {
    final a = photo('a.jpg', 0), b = photo('b.jpg', minute);
    final g = groupDuplicates({a: const Prints('1:a', 0x0F0F0F0F0F0F0F0F, 1), b: const Prints('2:b', 0x7070707070707070, 2)});
    expect(g, isEmpty);
  });
}
