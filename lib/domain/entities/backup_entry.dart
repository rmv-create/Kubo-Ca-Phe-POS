import 'package:meta/meta.dart';

/// Why a backup was taken. Pre-migration and pre-restore backups are protected
/// from pruning, because those are the ones that matter when something has
/// gone wrong.
enum BackupReason {
  manual('manual', 'Manual backup'),
  automaticDaily('auto_daily', 'Daily automatic backup'),
  preMigration('pre_migration', 'Before database upgrade'),
  preRestore('pre_restore', 'Before restoring a backup'),
  preRiskyOperation('pre_risky', 'Before a risky operation'),
  dailyClosing('daily_closing', 'Daily closing'),

  /// A file copied into the backups folder from somewhere else — the old
  /// phone, iCloud Drive, a chat. Never pruned: she put it there on purpose.
  imported('imported', 'Brought in from another device');

  const BackupReason(this.code, this.label);

  final String code;
  final String label;

  /// Backups that must never be pruned away automatically.
  bool get isProtected =>
      this == BackupReason.preMigration ||
      this == BackupReason.preRestore ||
      this == BackupReason.imported;

  static BackupReason fromCode(String code) => BackupReason.values.firstWhere(
    (BackupReason r) => r.code == code,
    orElse: () => BackupReason.manual,
  );
}

@immutable
class BackupEntry {
  const BackupEntry({
    required this.fileName,
    required this.createdAt,
    required this.reason,
    required this.sizeBytes,
    required this.schemaVersion,
    required this.sha256,
    this.sentAt,
  });

  factory BackupEntry.fromJson(Map<String, Object?> json) => BackupEntry(
    fileName: json['file_name']! as String,
    createdAt: DateTime.parse(json['created_at']! as String),
    reason: BackupReason.fromCode(json['reason']! as String),
    sizeBytes: json['size_bytes']! as int,
    schemaVersion: json['schema_version']! as int,
    sha256: json['sha256']! as String,
    sentAt: json['sent_at'] == null
        ? null
        : DateTime.parse(json['sent_at']! as String),
  );

  final String fileName;
  final DateTime createdAt;
  final BackupReason reason;
  final int sizeBytes;
  final int schemaVersion;
  final String sha256;

  /// When a copy of this file was sent off the device — to iCloud Drive, a
  /// chat, an email. Null means the only copy is on this phone.
  final DateTime? sentAt;

  /// True once there is a copy somewhere a dropped phone cannot take with it.
  bool get isOffDevice => sentAt != null;

  BackupEntry copyWith({DateTime? sentAt}) => BackupEntry(
    fileName: fileName,
    createdAt: createdAt,
    reason: reason,
    sizeBytes: sizeBytes,
    schemaVersion: schemaVersion,
    sha256: sha256,
    sentAt: sentAt ?? this.sentAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'file_name': fileName,
    'created_at': createdAt.toUtc().toIso8601String(),
    'reason': reason.code,
    'size_bytes': sizeBytes,
    'schema_version': schemaVersion,
    'sha256': sha256,
    if (sentAt != null) 'sent_at': sentAt!.toUtc().toIso8601String(),
  };

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
