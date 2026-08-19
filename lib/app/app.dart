import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

    return MaterialApp.router(
      title: businessName,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
    );
  }
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
