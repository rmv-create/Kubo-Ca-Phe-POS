import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/responsive/form_factor.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/money/money.dart';
import '../../../shared/widgets/money_text.dart';
import '../../../shared/widgets/section_header.dart';

/// The POS frame.
///
/// Phase 1 establishes the layout, the zones and their proportions on both
/// form factors. The menu grid arrives with Phase 2 and the working order flow
/// with Phase 3; nothing on this screen writes to the database yet, and the
/// controls that are not wired up are visibly disabled rather than fake.
class PosScreen extends ConsumerWidget {
  const PosScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String businessName = ref
        .watch(settingsControllerProvider)
        .businessName;

    return ResponsiveBuilder(
      compact: (BuildContext context) =>
          _CompactPos(businessName: businessName),
      medium: (BuildContext context) =>
          _WidePos(businessName: businessName, threePane: false),
      expanded: (BuildContext context) =>
          _WidePos(businessName: businessName, threePane: true),
    );
  }
}

// ─────────────────────────── iPhone ───────────────────────────

/// One column. The menu scrolls; the customer strip is pinned to the top and
/// the order + payment block is pinned to the bottom, inside the thumb arc.
class _CompactPos extends StatelessWidget {
  const _CompactPos({required this.businessName});

  final String businessName;

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: Column(
      children: <Widget>[
        _PosHeader(businessName: businessName),
        const _CustomerStrip(),
        const Expanded(child: _MenuPane()),
        const _OrderSummaryBar(),
      ],
    ),
  );
}

// ─────────────────────────── iPad ───────────────────────────

/// Landscape gets three panes so a whole order — pick, configure, review, pay —
/// happens without a single navigation or modal. Portrait drops the middle
/// pane, since there is not enough width for three comfortable columns.
class _WidePos extends StatelessWidget {
  const _WidePos({required this.businessName, required this.threePane});

  final String businessName;
  final bool threePane;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      children: <Widget>[
        _PosHeader(businessName: businessName),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                flex: threePane ? 4 : 6,
                child: const Column(
                  children: <Widget>[
                    _CustomerStrip(),
                    Expanded(child: _MenuPane()),
                  ],
                ),
              ),
              if (threePane) ...<Widget>[
                const VerticalDivider(width: 1),
                const Expanded(flex: 4, child: _ConfigurationPane()),
              ],
              const VerticalDivider(width: 1),
              const SizedBox(width: 340, child: _OrderPane()),
            ],
          ),
        ),
      ],
    ),
  );
}

// ─────────────────────────── pieces ───────────────────────────

class _PosHeader extends StatelessWidget {
  const _PosHeader({required this.businessName});

  final String businessName;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KuboSpacing.lg,
        KuboSpacing.md,
        KuboSpacing.sm,
        KuboSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.coffee, color: theme.colorScheme.primary),
          const SizedBox(width: KuboSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(businessName, style: theme.textTheme.titleMedium),
                Text('New order', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Customer is optional and always skippable — a sale is never blocked on it.
class _CustomerStrip extends StatelessWidget {
  const _CustomerStrip();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        KuboSpacing.lg,
        0,
        KuboSpacing.lg,
        KuboSpacing.md,
      ),
      padding: const EdgeInsets.all(KuboSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(KuboRadius.lg),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: 18,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.person_outline,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: KuboSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Guest', style: theme.textTheme.titleSmall),
                Text(
                  'Search or add a customer',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const _ComingSoonButton(
            label: 'Search',
            icon: Icons.search,
            phase: 'Phase 3',
          ),
        ],
      ),
    );
  }
}

class _MenuPane extends StatelessWidget {
  const _MenuPane();

  /// Category names come from `product_categories` once Phase 2 seeds the
  /// menu. They are shown here so the layout can be judged at real size.
  static const List<String> _placeholderCategories = <String>[
    'Classics',
    'Specialty Coffee',
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: KuboTouch.chip + KuboSpacing.md,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
            itemCount: _placeholderCategories.length,
            separatorBuilder: (_, __) => const SizedBox(width: KuboSpacing.sm),
            itemBuilder: (BuildContext context, int index) => Center(
              child: ChoiceChip(
                label: Text(_placeholderCategories[index]),
                selected: index == 0,
                onSelected: null,
              ),
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(KuboSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.local_cafe_outlined,
                    size: 44,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(height: KuboSpacing.md),
                  Text(
                    'No products yet',
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: KuboSpacing.xs),
                  Text(
                    'Products, sizes and prices are set up in Phase 2. '
                    'Real prices and recipes come from the owner — nothing is '
                    'invented here.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// iPad-only middle pane: size and customisation live here instead of in a
/// sheet, because there is room for them.
class _ConfigurationPane extends StatelessWidget {
  const _ConfigurationPane();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Configure'),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(KuboSpacing.xl),
              child: Text(
                'Pick a drink to choose its size and customisations.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// iPad-only right pane: the running order and payment, always visible.
class _OrderPane extends StatelessWidget {
  const _OrderPane();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionHeader('Current order'),
          Expanded(
            child: Center(
              child: Text(
                'No items yet',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.all(KuboSpacing.lg),
            child: _PaymentBlock(),
          ),
        ],
      ),
    );
  }
}

/// iPhone-only bottom block: total, payment method, complete. Never scrolls
/// away.
class _OrderSummaryBar extends StatelessWidget {
  const _OrderSummaryBar();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: const SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            KuboSpacing.lg,
            KuboSpacing.md,
            KuboSpacing.lg,
            KuboSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[_PaymentBlock()],
          ),
        ),
      ),
    );
  }
}

class _PaymentBlock extends StatelessWidget {
  const _PaymentBlock();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'No items',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const MoneyText(Money.zero, emphasised: true),
          ],
        ),
        const SizedBox(height: KuboSpacing.md),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Cash'),
              ),
            ),
            const SizedBox(width: KuboSpacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.smartphone_outlined),
                label: const Text('GCash'),
              ),
            ),
          ],
        ),
        const SizedBox(height: KuboSpacing.sm),
        const SizedBox(
          height: KuboTouch.primaryAction,
          child: FilledButton(onPressed: null, child: Text('COMPLETE ORDER')),
        ),
      ],
    );
  }
}

class _ComingSoonButton extends StatelessWidget {
  const _ComingSoonButton({
    required this.label,
    required this.icon,
    required this.phase,
  });

  final String label;
  final IconData icon;
  final String phase;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Arrives in $phase',
    child: OutlinedButton.icon(
      onPressed: null,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, KuboTouch.minTarget),
        padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.md),
      ),
    ),
  );
}
