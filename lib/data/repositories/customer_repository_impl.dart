import '../../core/errors/app_exception.dart';
import '../../core/money/money.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/customer.dart';
import '../../domain/repositories/customer_repository.dart';
import '../db/app_database.dart';

class CustomerRepositoryImpl implements CustomerRepository {
  CustomerRepositoryImpl(this._db, this._clock);

  final AppDatabase _db;
  final Clock _clock;

  /// A configuration has to have been ordered this many times before it counts
  /// as a usual. One past order is a past order, not a habit.
  static const int usualMinimumOccurrences = 2;

  @override
  Future<List<Customer>> search(String query, {int limit = 20}) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return recent(limit: limit);

    // Match a mobile whether or not she typed the spaces or dashes.
    final String digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
    final String namePattern = '%${_escape(trimmed)}%';

    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      '''
      SELECT * FROM customers
      WHERE is_active = 1
        AND (name LIKE ? ESCAPE '\\' COLLATE NOCASE
             ${digits.isEmpty ? '' : "OR REPLACE(REPLACE(REPLACE(IFNULL(mobile, ''), ' ', ''), '-', ''), '+', '') LIKE ?"})
      ORDER BY
        CASE WHEN name LIKE ? ESCAPE '\\' COLLATE NOCASE THEN 0 ELSE 1 END,
        last_visit_at DESC,
        name COLLATE NOCASE
      LIMIT ?
      ''',
      <Object?>[
        namePattern,
        if (digits.isNotEmpty) '%$digits%',
        '${_escape(trimmed)}%',
        limit,
      ],
    );
    return rows.map(_customer).toList();
  }

  @override
  Future<List<Customer>> recent({int limit = 8}) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'customers',
      where: 'is_active = 1',
      orderBy: 'last_visit_at DESC, created_at DESC',
      limit: limit,
    );
    return rows.map(_customer).toList();
  }

  @override
  Future<Customer?> byId(int id) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'customers',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : _customer(rows.first);
  }

  @override
  Future<int> create({required String name, String? mobile}) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const ValidationException(
        'A customer needs a name.',
        field: 'name',
      );
    }
    final String now = _clock.nowIso();
    return _db.db.insert('customers', <String, Object?>{
      'name': trimmed,
      'mobile': mobile?.trim().isEmpty ?? true ? null : mobile!.trim(),
      'created_at': now,
      'updated_at': now,
      'visit_count': 0,
      'order_count': 0,
      'item_count': 0,
      'total_spend_centavos': 0,
      'segment': CustomerSegment.newCustomer.code,
      'is_active': 1,
    });
  }

  @override
  Future<void> update(Customer customer) async {
    final String trimmed = customer.name.trim();
    if (trimmed.isEmpty) {
      throw const ValidationException(
        'A customer needs a name.',
        field: 'name',
      );
    }
    await _db.db.update(
      'customers',
      <String, Object?>{
        'name': trimmed,
        'mobile': customer.mobile?.trim().isEmpty ?? true
            ? null
            : customer.mobile!.trim(),
        'notes': customer.notes,
        'is_active': customer.isActive ? 1 : 0,
        'updated_at': _clock.nowIso(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[customer.id],
    );
  }

  @override
  Future<List<CustomerOrderPattern>> patternsFor(int customerId) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'customer_order_patterns',
      where: 'customer_id = ?',
      whereArgs: <Object?>[customerId],
      orderBy: 'occurrence_count DESC, last_ordered_at DESC',
    );
    return rows.map(_pattern).toList();
  }

  @override
  Future<UsualOrder?> usualFor(int customerId) async {
    final Customer? customer = await byId(customerId);
    if (customer == null) return null;

    final List<CustomerOrderPattern> patterns = await patternsFor(customerId);
    if (patterns.isEmpty) return null;

    CustomerOrderPattern? chosen;
    bool isSaved = false;

    // A usual the owner pinned always wins over the calculated one.
    final int? savedId = customer.savedUsualPatternId;
    if (savedId != null) {
      for (final CustomerOrderPattern p in patterns) {
        if (p.id == savedId) {
          chosen = p;
          isSaved = true;
          break;
        }
      }
    }

    // Otherwise: most repeated, and only once it has actually repeated.
    // `patternsFor` already orders by count then recency, so the first row
    // that clears the threshold is the answer — deliberately *not* the most
    // recent order, which is often a one-off.
    chosen ??= patterns
        .where(
          (CustomerOrderPattern p) =>
              p.occurrenceCount >= usualMinimumOccurrences,
        )
        .firstOrNull;

    if (chosen == null) return null;
    return _describe(chosen, isSaved: isSaved);
  }

  @override
  Future<void> saveUsual({
    required int customerId,
    required int patternId,
  }) async {
    final List<Map<String, Object?>> owned = await _db.db.query(
      'customer_order_patterns',
      where: 'id = ? AND customer_id = ?',
      whereArgs: <Object?>[patternId, customerId],
      limit: 1,
    );
    if (owned.isEmpty) {
      throw const NotFoundException('That order is not on this customer.');
    }
    await _db.db.update(
      'customers',
      <String, Object?>{
        'saved_usual_pattern_id': patternId,
        'updated_at': _clock.nowIso(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[customerId],
    );
  }

  @override
  Future<void> clearUsual(int customerId) async {
    await _db.db.update(
      'customers',
      <String, Object?>{
        'saved_usual_pattern_id': null,
        'updated_at': _clock.nowIso(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[customerId],
    );
  }

  /// Turns a pattern into something displayable, pricing it at *today's*
  /// prices rather than what it cost last time.
  Future<UsualOrder?> _describe(
    CustomerOrderPattern pattern, {
    required bool isSaved,
  }) async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      '''
      SELECT p.name AS product_name,
             s.name AS size_name,
             ps.price_centavos AS price
      FROM products p
      JOIN sizes s ON s.id = ?
      LEFT JOIN product_sizes ps
             ON ps.product_id = p.id AND ps.size_id = s.id
      WHERE p.id = ?
      ''',
      <Object?>[pattern.sizeId, pattern.productId],
    );
    // The drink or size may have been removed since; there is no usual to show.
    if (rows.isEmpty) return null;

    final Map<String, Object?> row = rows.first;
    int total = (row['price'] as int?) ?? 0;

    final List<String> optionNames = <String>[];
    if (pattern.optionIds.isNotEmpty) {
      final String placeholders = List<String>.filled(
        pattern.optionIds.length,
        '?',
      ).join(',');
      final List<Map<String, Object?>> optionRows = await _db.db.rawQuery(
        'SELECT o.name AS name, o.price_delta_centavos AS delta, '
        'g.display_order AS g_order, o.display_order AS o_order '
        'FROM customization_options o '
        'JOIN customization_groups g ON g.id = o.group_id '
        'WHERE o.id IN ($placeholders) '
        'ORDER BY g.display_order, o.display_order',
        pattern.optionIds,
      );
      for (final Map<String, Object?> o in optionRows) {
        optionNames.add(o['name']! as String);
        total += o['delta']! as int;
      }
    }

    return UsualOrder(
      pattern: pattern,
      isSaved: isSaved,
      productName: row['product_name']! as String,
      sizeName: row['size_name']! as String,
      optionNames: optionNames,
      price: Money(total),
    );
  }

  static String _escape(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  static Customer _customer(Map<String, Object?> r) => Customer(
    id: r['id']! as int,
    name: r['name']! as String,
    mobile: r['mobile'] as String?,
    createdAt: DateTime.parse(r['created_at']! as String),
    firstVisitAt: _date(r['first_visit_at']),
    lastVisitAt: _date(r['last_visit_at']),
    visitCount: r['visit_count']! as int,
    orderCount: r['order_count']! as int,
    itemCount: r['item_count']! as int,
    totalSpend: Money(r['total_spend_centavos']! as int),
    savedUsualPatternId: r['saved_usual_pattern_id'] as int?,
    storedSegment: CustomerSegment.fromCode(r['segment']! as String),
    isActive: r['is_active'] == 1,
    notes: r['notes'] as String?,
  );

  static CustomerOrderPattern _pattern(Map<String, Object?> r) =>
      CustomerOrderPattern(
        id: r['id']! as int,
        customerId: r['customer_id']! as int,
        signature: r['signature']! as String,
        productId: r['product_id']! as int,
        sizeId: r['size_id']! as int,
        optionIds: (r['option_ids_json']! as String)
            .split(',')
            .where((String s) => s.isNotEmpty)
            .map(int.parse)
            .toList(),
        occurrenceCount: r['occurrence_count']! as int,
        firstOrderedAt: DateTime.parse(r['first_ordered_at']! as String),
        lastOrderedAt: DateTime.parse(r['last_ordered_at']! as String),
      );

  static DateTime? _date(Object? value) =>
      value == null ? null : DateTime.parse(value as String);
}
