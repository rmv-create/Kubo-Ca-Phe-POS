import 'package:meta/meta.dart';

/// One thing that happened on one till, in terms another till can act on.
///
/// Local row ids mean nothing anywhere else, so a change never carries one.
/// The row is named by its uid, and anything it points at — the order a
/// line belongs to, the ingredient a movement moved — is named by *that*
/// row's uid too. The receiving till turns those back into its own ids.
@immutable
class SyncChange {
  const SyncChange({
    required this.changeId,
    required this.deviceId,
    required this.table,
    required this.rowUid,
    required this.op,
    required this.at,
    this.data = const <String, Object?>{},
  });

  factory SyncChange.fromJson(Map<String, Object?> json) => SyncChange(
    changeId: json['change_id']! as String,
    deviceId: json['device_id']! as String,
    table: json['table']! as String,
    rowUid: json['row_uid']! as String,
    op: json['op'] == 'delete' ? SyncOp.delete : SyncOp.upsert,
    at: json['at']! as String,
    data: (json['data'] as Map<Object?, Object?>? ?? <Object?, Object?>{}).map(
      (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
    ),
  );

  /// Unique for all time, across every till: the till's own name and its
  /// own count. This is what makes applying a change twice impossible.
  final String changeId;

  final String deviceId;
  final String table;
  final String rowUid;
  final SyncOp op;

  /// When it happened, by the clock of the till it happened on.
  final String at;

  /// The row itself, with foreign keys given as uids. Empty for a delete.
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => <String, Object?>{
    'change_id': changeId,
    'device_id': deviceId,
    'table': table,
    'row_uid': rowUid,
    'op': op == SyncOp.delete ? 'delete' : 'upsert',
    'at': at,
    if (op != SyncOp.delete) 'data': data,
  };

  @override
  String toString() => '${op.name} $table/$rowUid';
}

enum SyncOp { upsert, delete }

/// What came of taking in a batch of changes.
@immutable
class SyncApplied {
  const SyncApplied({
    required this.applied,
    required this.alreadyKnown,
    required this.waitingForParent,
    required this.ignoredAsOlder,
  });

  final int applied;

  /// Changes this till had already taken in. Not an error: every till
  /// broadcasts everything, and hearing the same thing twice is normal.
  final int alreadyKnown;

  /// Changes whose row points at something that has not arrived yet — an
  /// order line ahead of its order. Held, not dropped, and tried again.
  final int waitingForParent;

  /// Edits to the menu or a recipe that were older than what is here.
  final int ignoredAsOlder;

  bool get isEmpty =>
      applied == 0 &&
      alreadyKnown == 0 &&
      waitingForParent == 0 &&
      ignoredAsOlder == 0;

  @override
  String toString() =>
      'applied $applied, known $alreadyKnown, '
      'waiting $waitingForParent, older $ignoredAsOlder';
}
