import 'package:flutter_test/flutter_test.dart';
import 'package:myhato/features/catalog/catalog_repository.dart';

void main() {
  test('search input cannot inject PostgREST filter syntax', () {
    expect(sanitizeSearch('iphone,price_minor.lt.1'), 'iphone price_minor lt 1');
    expect(sanitizeSearch('  galaxy   s24 '), 'galaxy s24');
    expect(sanitizeSearch('a(b)*%c'), 'a b c');
  });

  test('CatalogQuery copyWith keeps filters and value equality works', () {
    const q = CatalogQuery(kind: 'phones', brandId: 'b1', sort: SortOption.priceAsc);
    final q2 = q.copyWith(search: 'x');
    expect(q2.brandId, 'b1');
    expect(q2.sort, SortOption.priceAsc);
    expect(q2.copyWith(brandId: null).brandId, isNull);
    expect(const CatalogQuery(kind: 'phones'), const CatalogQuery(kind: 'phones'));
  });
}
