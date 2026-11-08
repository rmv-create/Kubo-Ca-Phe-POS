import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../data/cloud/cloud_backup_service.dart';
import '../../../data/db/archive_file.dart';
import '../../../data/db/database_archive.dart';
import '../../../domain/entities/backup_entry.dart';
import '../../../domain/entities/reporting.dart';
import '../../../domain/services/nightly_backup_service.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/section_header.dart';
import '../../backup/presentation/backup_screen.dart';
import '../../backup/presentation/send_backup.dart';
import 'reports_screen.dart';

/// Close the day: check the figures, confirm, and lock them in.
class DailyClosingScreen extends ConsumerWidget {
  const DailyClosingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String today = ref.watch(todayBusinessDateProvider);
    final AsyncValue<SalesSummary> summary = ref.watch(
      dailySummaryProvider(today),
    );
    final AsyncValue<DailyClosing?> existing = ref.watch(
      closingProvider(today),
    );
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Daily closing')),
      body: AsyncView<DailyClosing?>(
        value: existing,
        builder: (BuildContext context, DailyClosing? closed) => ListView(
          padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
          children: <Widget>[
            if (closed != null)
              Container(
                margin: const EdgeInsets.all(KuboSpacing.lg),
                padding: const EdgeInsets.all(KuboSpacing.lg),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(KuboRadius.md),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('DAY CLOSED', style: theme.textTheme.labelSmall),
                    const SizedBox(height: KuboSpacing.xs),
                    Text(
                      'Closed at '
                      '${closed.closedAt.toLocal().toString().substring(11, 16)}. '
                      'The figures below are the ones locked in.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            SectionHeader(today),
            if (closed != null)
              SummaryCard(summary: closed.summary)
            else
              AsyncView<SalesSummary>(
                value: summary,
                builder: (BuildContext context, SalesSummary s) =>
                    SummaryCard(summary: s),
              ),
            if (closed == null) ...<Widget>[
              Padding(
                padding: const EdgeInsets.all(KuboSpacing.lg),
                child: Text(
                  'Closing the day saves these totals as they stand. Orders '
                  'taken afterwards belong to the next trading day.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
                child: SizedBox(
                  height: KuboTouch.primaryAction,
                  child: FilledButton(
                    onPressed: () => _close(context, ref, today),
                    child: const Text('CLOSE THE DAY'),
                  ),
                ),
              ),
            ],
            const SectionHeader('Earlier days'),
            _RecentClosings(),
          ],
        ),
      ),
    );
  }

  Future<void> _close(BuildContext context, WidgetRef ref, String day) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Close $day?'),
        content: const Text(
          "Today's totals will be saved as they are now. You can still take "
          'orders — they will count towards the next day.\n\n'
          'A backup is taken as the day closes, and you will be offered the '
          'chance to send a copy of it off the phone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Close the day'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    BackupEntry? backup;
    try {
      await ref.read(reportingServiceProvider).closeDay(day);
    } on AppException catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }
    ref.read(salesRevisionProvider.notifier).bump();

    // In a browser there is no file to copy: the database lives inside the
    // browser's own storage and `dart:io` is not there at all. Closing the
    // day used to try anyway and throw where nothing was catching, so the
    // day closed and the screen never said so. In a browser the day's copy
    // is the file she saves herself, offered below.
    if (!kIsWeb) {
      try {
        // The day's figures are final, so this is the copy worth keeping.
        backup = await ref
            .read(backupServiceProvider)
            .create(reason: BackupReason.dailyClosing);
        ref.invalidate(backupListProvider);
      } on Object catch (error) {
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text('$day closed, but the backup failed: '
                '$error')),
          );
      }
    }

    // The copy that goes up by itself, into her own Firebase. This is the
    // one that survives a lost phone without anybody remembering anything.
    final BackupRound round = await ref
        .read(nightlyBackupProvider)
        .run(day: day, force: true);
    ref.invalidate(cloudBackupsProvider);

    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            switch (round.outcome) {
              BackupOutcome.sent => '$day closed \u00b7 backed up to the cloud',
              BackupOutcome.alreadyDone => '$day closed \u00b7 already backed up',
              _ => '$day closed',
            },
          ),
        ),
      );

    // Only when the automatic copy did not go. She should not be asked to
    // do by hand what has just been done for her; she should be asked when
    // it has not.
    if (!round.sent && context.mounted) {
      await _offerToSaveAFile(context, ref, day, because: round.message);
      return;
    }
    if (kIsWeb) return;

    // The backup lives beside the database it was taken from, which is no
    // help at all if the phone goes. Sent here, at the one moment in the day
    // when she is finished and the figures are settled.
    if (backup == null || !context.mounted) return;

    final CloudBackupOutcome outcome = await ref
        .read(cloudBackupServiceProvider)
        .send(backup);
    ref.invalidate(backupListProvider);
    if (!context.mounted) return;

    if (outcome.isSuccess) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('$day saved to the cloud')));
      return;
    }

    // No account, no signal, or a sign-in that has lapsed. Rather than leave
    // the day's work on one phone, she is offered the two-tap way out.
    await _offerToSend(context, ref, backup, day, because: outcome);
  }

  /// In a browser, the day's copy is a file she keeps herself.
  ///
  /// Asked here rather than left to her to remember, because closing is the
  /// one moment in the day when the figures are settled and she is not
  /// holding a cup.
  Future<void> _offerToSaveAFile(
    BuildContext context,
    WidgetRef ref,
    String day, {
    String? because,
  }) async {
    final bool? save = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Save today\u2019s copy by hand?'),
        content: Text(
          '${because ?? 'The automatic backup did not go up.'}\n\n'
          'The whole shop lives inside this browser, and a browser can '
          'clear its own storage. A file saved now is the only copy that '
          'survives a lost phone \u2014 put it in Google Drive, iCloud, or '
          'even message it to yourself.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('SAVE A COPY'),
          ),
        ],
      ),
    );
    if (save != true || !context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await saveArchive(
        await DatabaseArchive(
          ref.read(databaseProvider).db,
          ref.read(clockProvider),
        ).export(),
        'kubo-${day.replaceAll('-', '')}.sql',
        into: ref.read(backupServiceProvider).backupDirectory,
      );
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('$day is safe off the phone')));
    } on Object catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _offerToSend(
    BuildContext context,
    WidgetRef ref,
    BackupEntry backup,
    String day, {
    required CloudBackupOutcome because,
  }) async {
    final bool? send = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Keep a copy off the phone?'),
        content: Text(
          '${because.message}.\n\n'
          "Today's backup is ${backup.sizeLabel}. Saving it to Drive, iCloud "
          'or even a message to yourself takes a second, and it is the only '
          'copy that survives a lost or broken phone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send a copy'),
          ),
        ],
      ),
    );
    if (send != true || !context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool sent = await sendBackupOffDevice(context, ref, backup);
    if (!sent) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('$day is safe off the phone')));
  }
}

class _RecentClosings extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return FutureBuilder<List<DailyClosing>>(
      future: ref.watch(reportingServiceProvider).recentClosings(limit: 14),
      builder:
          (BuildContext context, AsyncSnapshot<List<DailyClosing>> snapshot) {
            final List<DailyClosing> closings =
                snapshot.data ?? <DailyClosing>[];
            if (closings.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
                child: Text(
                  'No days closed yet.',
                  style: theme.textTheme.bodySmall,
                ),
              );
            }
            return Column(
              children: <Widget>[
                for (final DailyClosing c in closings)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.event_available_outlined),
                    title: Text(c.businessDate),
                    subtitle: Text(
                      '${c.summary.orderCount} orders · '
                      '${c.summary.revenue.format()} · '
                      'margin ${c.summary.marginLabel}',
                    ),
                  ),
              ],
            );
          },
    );
  }
}
