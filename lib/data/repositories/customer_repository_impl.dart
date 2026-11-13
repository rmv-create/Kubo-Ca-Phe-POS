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
  Future<List<Customer>> search(
    String query, {
    int limit = 20,
    bool alphabetical = false,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) {
      // Two different questions. At the counter it is "who is standing in
      // front of me", and the answer is almost always somebody who was in
      // recently, so the till lists them that way. On the customers page it
      // is "where is James in this list", and the answer is A to Z.
      return alphabetical ? byName(limit: limit) : recent(limit: limit);
    }

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
        ${alphabetical ? '' : 'last_visit_at DESC,'}
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

  /// Everybody, A to Z.
  @override
  Future<List<Customer>> byName({int limit = 500}) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'customers',
      where: 'is_active = 1',
      orderBy: 'name COLLATE NOCASE, id',
      limit: limit,
    );
    return rows.map(_customer).toList();
  }

  /// The ones she has taken off the list, so that she can put one back.
  ///
  /// Kept out of [search] and [recent] on purpose: the point of archiving is
  /// that they stop coming up while she is serving.
  @override
  Future<List<Customer>> archived({int limit = 200}) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'customers',
      where: 'is_active = 0',
      orderBy: 'name COLLATE NOCASE',
      limit: limit,
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
  Future<int> create({
    required String name,
    String? mobile,
    String? notes,
  }) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const ValidationException(
        'A customer needs a name.',
        field: 'name',
      );
    }
    final String? note = _tidy(notes);
    await _refuseIfTaken(name: trimmed, notes: note);

    final String now = _clock.nowIso();
    return _db.db.insert('customers', <String, Object?>{
      'name': trimmed,
      'mobile': _tidy(mobile),
      'notes': note,
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

  static String? _tidy(String? value) {
    final String trimmed = (value ?? '').trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Two people called James are fine. Two people called James with nothing
  /// to tell them apart are not.
  ///
  /// The note is what separates them — "office", "classmate" — so a repeated
  /// name is allowed as long as the note differs. A repeated name with the
  /// same note, or with no note on either, is refused: picking the wrong one
  /// at the counter puts a drink on a stranger's tab, and there would have
  /// been no way to tell which was which.
  Future<void> _refuseIfTaken({
    required String name,
    required String? notes,
    int? exceptId,
  }) async {
    final List<Map<String, Object?>> clashes = await _db.db.rawQuery(
      'SELECT id, notes, is_active FROM customers '
      'WHERE LOWER(TRIM(name)) = ?${exceptId == null ? '' : ' AND id != ?'}',
      <Object?>[name.toLowerCase(), if (exceptId != null) exceptId],
    );
    if (clashes.isEmpty) return;

    final String mine = (notes ?? '').toLowerCase();
    for (final Map<String, Object?> row in clashes) {
      final String theirs = ((row['notes'] as String?) ?? '').toLowerCase();
      if (theirs != mine) continue;

      final bool archived = row['is_active'] != 1;
      if (mine.isEmpty) {
        throw ValidationException(
          archived
              ? 'There is already an archived customer called $name. Restore '
                    'that one, or add a note to tell this one apart.'
              : 'There is already a customer called $name. Add a note to '
                    'tell them apart \u2014 "office", "classmate".',
          field: 'name',
        );
      }
      throw ValidationException(
        'There is already a $name with that same note. Make the note '
        'different so you can tell them apart at the counter.',
        field: 'notes',
      );
    }
  }

  /// Takes a customer off the list without losing what they bought.
  ///
  /// Their orders stay exactly as they are; they simply stop being offered
  /// when she searches. This is the reversible one.
  @override
  Future<void> archive(int id) async => _setActive(id, false);

  /// Puts an archived customer back on the list.
  @override
  Future<void> restore(int id) async {
    final Customer? who = await byId(id);
    if (who == null) throw const NotFoundException('That customer is gone.');
    await _refuseIfTaken(name: who.name, notes: who.notes, exceptId: id);
    await _setActive(id, true);
  }

  Future<void> _setActive(int id, bool active) async {
    final int changed = await _db.db.update(
      'customers',
      <String, Object?>{
        'is_active': active ? 1 : 0,
        'updated_at': _clock.nowIso(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    if (changed == 0) throw const NotFoundException('That customer is gone.');
  }

  /// Forgets a customer entirely.
  ///
  /// What they bought stays on the books \u2014 the money came in and the
  /// stock went out, and neither becomes untrue because she no longer keeps
  /// their name. Their past orders simply stop being anybody's, exactly as
  /// if they had been rung up as a guest.
  @override
  Future<void> delete(int id) async {
    final int changed = await _db.db.delete(
      'customers',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    if (changed == 0) throw const NotFoundException('That customer is gone.');
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
    await _refuseIfTaken(
      name: trimmed,
      notes: _tidy(customer.notes),
      exceptId: customer.id,
    );
    await _db.db.update(
      'customers',
      <String, Object?>{
        'name': trimmed,
        'mobile': customer.mobile?.trim().isEmpty ?? true
            ? null
            : customer.mobile!.trim(),
        'notes': _tidy(customer.notes),
        'birthday': customer.birthday,
        'segment': customer.storedSegment.code,
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
  Future<UsualOrder?> lastOrderedFor(int customerId) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'customer_order_patterns',
      where: 'customer_id = ?',
      whereArgs: <Object?>[customerId],
      orderBy: 'last_ordered_at DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _describe(_pattern(rows.first), isSaved: false);
  }

  @override
  Future<List<LapsedCustomer>> lapsed({
    int minimumOrders = 2,
    int limit = 50,
  }) async {
    final DateTime now = _clock.now();

    // Their own rhythm, not one rule for everybody. Somebody who came in
    // every Tuesday for a year is missed after a fortnight; somebody who
    // comes once a month is not. The gap that matters is the gap between
    // their first visit and their last, divided by the visits in between.
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      '''
      SELECT *,
             CAST(julianday(?) - julianday(last_visit_at) AS INTEGER)
               AS days_away,
             CASE WHEN order_count > 1
                  THEN (julianday(last_visit_at) - julianday(first_visit_at))
                       / (order_count - 1)
                  ELSE NULL END AS usual_gap
      FROM customers
      WHERE is_active = 1
        AND order_count >= ?
        AND last_visit_at IS NOT NULL
        AND days_away >= 7
        AND (usual_gap IS NULL OR days_away > usual_gap * 2)
      ORDER BY total_spend_centavos DESC, days_away DESC
      LIMIT ?
      ''',
      <Object?>[now.toUtc().toIso8601String(), minimumOrders, limit],
    );

    return <LapsedCustomer>[
      for (final Map<String, Object?> r in rows)
        LapsedCustomer(
          customer: _customer(r),
          daysAway: (r['days_away'] as num?)?.toInt() ?? 0,
          usualGapDays: (r['usual_gap'] as num?)?.round(),
        ),
    ];
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
    birthday: r['birthday'] as String?,
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
