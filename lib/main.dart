import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/bootstrap.dart';
import 'app/theme/app_theme.dart';
import 'app/theme/kubo_tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The POS is used in portrait on iPhone and in either orientation on iPad;
  // the layout adapts to whatever width it is given.
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  try {
    final AppBootstrap bootstrap = await bootstrapApp();
    runApp(
      ProviderScope(overrides: bootstrap.overrides, child: const KuboApp()),
    );
  } catch (error, stack) {
    // Starting without a working database would mean silently losing sales.
    // Say so instead.
    runApp(_StartupFailureApp(error: error, stack: stack));
  }
}

class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.error, required this.stack});

  final Object error;
  final StackTrace stack;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Kubo Cà Phê',
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(KuboSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SizedBox(height: KuboSpacing.xxl),
              Icon(
                Icons.error_outline,
                size: 44,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: KuboSpacing.lg),
              Text(
                'Kubo could not start',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: KuboSpacing.sm),
              const Text(
                'The database could not be opened, so no orders can be '
                'recorded. Nothing has been changed or lost. Please close '
                'the app and reopen it; if this keeps happening, restore '
                'the most recent backup.',
              ),
              const SizedBox(height: KuboSpacing.xl),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    '$error\n\n$stack',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
