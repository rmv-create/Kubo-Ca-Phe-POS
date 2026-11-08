import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/time/clock.dart';
import '../domain/entities/business_settings.dart';
import '../domain/services/shop_access_service.dart';
import '../features/access/presentation/welcome_screen.dart';
import '../features/backup/presentation/backup_screen.dart';
import 'providers.dart';
import 'router.dart';
import 'theme/app_theme.dart';
import 'theme/kubo_tokens.dart';

class KuboApp extends ConsumerStatefulWidget {
  const KuboApp({super.key});

  @override
  ConsumerState<KuboApp> createState() => _KuboAppState();
}

class _KuboAppState extends ConsumerState<KuboApp> {
  late final GoRouter _router = createRouter();
  bool _askedForTonightsCopy = false;

  /// Sends today's copy up if it has not gone yet.
  ///
  /// Closing the day does this too, but she will not always close the day —
  /// she will be tired, or busy, or the phone will be at four per cent. A
  /// backup that only happens when somebody remembers is not a backup, so
  /// opening the app is another chance to take one. It costs nothing when
  /// today's has already gone.
  void _backUpIfTodayHasNotGone() {
    if (_askedForTonightsCopy) return;
    _askedForTonightsCopy = true;
    final BusinessSettings settings = ref.read(settingsControllerProvider);
    final String today = BusinessDay(
      cutoffHour: settings.businessDayCutoffHour,
    ).dateOf(ref.read(clockProvider).now());
    unawaited(
      ref
          .read(nightlyBackupProvider)
          .run(day: today)
          .then((_) => null)
          .catchError((Object _) => null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String businessName = ref
        .watch(settingsControllerProvider)
        .businessName;
    final bool restartRequired = ref.watch(restartRequiredProvider);

    if (restartRequired) {
      return MaterialApp(
        title: businessName,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        debugShowCheckedModeBanner: false,
        home: const _RestartRequiredScreen(),
      );
    }

    // Nothing of the shop is built until this phone is known to be in one.
    // The welcome screen is not a page inside the app; it stands in front of
    // it, because a phone that has not been let in has no POS to show.
    final AsyncValue<ShopStanding> standing = ref.watch(shopStandingProvider);
    final Widget? gate = standing.when(
      loading: () => const _Opening(),
      error: (Object error, StackTrace _) => const WelcomeScreen(),
      data: (ShopStanding value) =>
          value == ShopStanding.inside ? null : const WelcomeScreen(),
    );
    if (gate != null) {
      return MaterialApp(
        title: businessName,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        debugShowCheckedModeBanner: false,
        home: gate,
      );
    }

    _backUpIfTodayHasNotGone();

    return MaterialApp.router(
      title: businessName,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
    );
  }
}

/// A blank moment while the app works out whether this phone is in a shop.
/// Deliberately almost empty: showing a POS and then snatching it away would
/// be worse than showing nothing for half a second.
class _Opening extends StatelessWidget {
  const _Opening();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

/// Shown after a restore. The open database connection no longer matches the
/// file on disk, so the app stops rather than writing to a stale handle.
class _RestartRequiredScreen extends StatelessWidget {
  const _RestartRequiredScreen();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(KuboSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.restart_alt,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: KuboSpacing.lg),
              Text('Backup restored', style: theme.textTheme.headlineSmall),
              const SizedBox(height: KuboSpacing.sm),
              Text(
                'Close Kubo completely and open it again to continue.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
