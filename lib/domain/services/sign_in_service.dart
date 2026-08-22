import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/errors/app_exception.dart';
import '../../core/time/clock.dart';
import '../../data/db/app_database.dart';
import '../entities/app_user.dart';

/// Who is using the app, and what they may see.
///
/// ## What this protects, and what it does not
///
/// This is a **staff separation**, not a security boundary. It stops the
/// barista opening the books, seeing what each drink costs to make, editing
/// recipes or exporting the customer list. That is the actual problem the
/// owner has, and it solves it.
///
/// It does **not** protect the data from someone determined. A four-digit PIN
/// has ten thousand possibilities, and anyone holding the device — or the
/// database file, or a shared web link — can work through them offline. The
/// PIN is stored as a salted SHA-256 hash so it is not readable at a glance,
/// and that is the honest limit of it. Anything genuinely confidential belongs
/// behind the device's own passcode and a private link, not behind this.
class SignInService {
  const SignInService({required AppDatabase database, required Clock clock})
    : _db = database,
      _clock = clock;

  final AppDatabase _db;
  final Clock _clock;

  /// Minimum PIN length. Four is what a phone lock screen asks for and what
  /// someone will actually use ten times a day.
  static const int minPinLength = 4;

  /// Everyone who can sign in.
  Future<List<AppUser>> users({bool includeInactive = false}) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'app_users',
      where: includeInactive ? null : 'is_active = 1',
      orderBy: "role = 'owner' DESC, name COLLATE NOCASE",
    );
    return rows.map(_fromRow).toList();
  }

  /// Whether anybody has been set up yet. False means the app is wide open and
  /// should say so.
  Future<bool> hasAnyUser() async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      'SELECT COUNT(*) AS n FROM app_users WHERE is_active = 1',
    );
    return ((rows.first['n'] as int?) ?? 0) > 0;
  }

  /// Adds someone. The PIN is salted and hashed before it touches the disk.
  Future<AppUser> addUser({
    required String name,
    required UserRole role,
    required String pin,
  }) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) throw const BusinessRuleException('Give them a name.');
    _checkPin(pin);

    final String salt = _newSalt();
    final String now = _clock.nowIso();
    try {
      final int id = await _db.db.insert('app_users', <String, Object?>{
        'name': trimmed,
        'role': role.code,
        'pin_salt': salt,
        'pin_hash': _hash(pin, salt),
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });
      return AppUser(id: id, name: trimmed, role: role, isActive: true);
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw BusinessRuleException('"$trimmed" is already set up.');
      }
      rethrow;
    }
  }

  Future<void> setPin({required int userId, required String pin}) async {
    _checkPin(pin);
    final String salt = _newSalt();
    await _db.db.update(
      'app_users',
      <String, Object?>{
        'pin_salt': salt,
        'pin_hash': _hash(pin, salt),
        'updated_at': _clock.nowIso(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[userId],
    );
  }

  Future<void> setActive({required int userId, required bool isActive}) async {
    if (!isActive && await _isLastOwner(userId)) {
      throw const BusinessRuleException(
        'This is the only owner. Switching them off would lock everyone out '
        'of the management area.',
      );
    }
    await _db.db.update(
      'app_users',
      <String, Object?>{
        'is_active': isActive ? 1 : 0,
        'updated_at': _clock.nowIso(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[userId],
    );
  }

  /// Checks a PIN and returns the person it belongs to, or null.
  Future<AppUser?> signIn({required int userId, required String pin}) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'app_users',
      where: 'id = ? AND is_active = 1',
      whereArgs: <Object?>[userId],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final Map<String, Object?> row = rows.first;
    final String expected = row['pin_hash']! as String;
    if (!_matches(_hash(pin, row['pin_salt']! as String), expected)) {
      return null;
    }

    final String now = _clock.nowIso();
    await _db.db.update(
      'app_users',
      <String, Object?>{'last_signed_in_at': now},
      where: 'id = ?',
      whereArgs: <Object?>[row['id']],
    );
    return _fromRow(<String, Object?>{...row, 'last_signed_in_at': now});
  }

  Future<bool> _isLastOwner(int userId) async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      'SELECT COUNT(*) AS n FROM app_users '
      "WHERE role = 'owner' AND is_active = 1 AND id != ?",
      <Object?>[userId],
    );
    return ((rows.first['n'] as int?) ?? 0) == 0;
  }

  void _checkPin(String pin) {
    if (pin.length < minPinLength || int.tryParse(pin) == null) {
      throw const BusinessRuleException(
        'The PIN must be at least $minPinLength digits.',
      );
    }
  }

  String _newSalt() {
    final Random random = Random.secure();
    return base64Url.encode(List<int>.generate(16, (_) => random.nextInt(256)));
  }

  String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  /// Compares in constant time. Overkill against a local attacker who can read
  /// the hash anyway, but comparing secrets with `==` is a habit worth not
  /// having.
  bool _matches(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  AppUser _fromRow(Map<String, Object?> row) => AppUser(
    id: row['id']! as int,
    name: row['name']! as String,
    role: UserRole.fromCode(row['role']! as String),
    isActive: (row['is_active']! as int) == 1,
    lastSignedInAt: row['last_signed_in_at'] == null
        ? null
        : DateTime.parse(row['last_signed_in_at']! as String),
  );
}
