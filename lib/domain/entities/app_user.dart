import 'package:meta/meta.dart';

/// What someone signed in to the app is allowed to see.
enum UserRole {
  /// The business. Everything: sales, costs, recipes, stock, settings, backup.
  owner('owner', 'Owner'),

  /// The till. Takes orders and payments, sees customers and their usuals,
  /// and nothing about what anything costs or what the shop earns.
  barista('barista', 'Barista');

  const UserRole(this.code, this.label);

  final String code;
  final String label;

  /// Whether this role may open the Management area at all.
  bool get canManage => this == UserRole.owner;

  static UserRole fromCode(String code) => UserRole.values.firstWhere(
    (UserRole r) => r.code == code,
    // An unrecognised role gets the *smaller* set of powers, never the larger.
    orElse: () => UserRole.barista,
  );
}

@immutable
class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.role,
    required this.isActive,
    this.lastSignedInAt,
  });

  final int id;
  final String name;
  final UserRole role;
  final bool isActive;
  final DateTime? lastSignedInAt;

  bool get canManage => role.canManage;
}
