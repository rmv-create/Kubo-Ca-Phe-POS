import 'package:flutter/material.dart';

/// How much room the app currently has to work with.
///
/// This is deliberately about *available width*, not about "iPhone vs iPad":
/// an iPad running the app in a narrow Split View gets the phone layout,
/// which is the right answer.
enum FormFactor {
  /// iPhone, or a narrow iPad split. One column, bottom-anchored actions.
  compact,

  /// iPad portrait. Two columns: menu + running order.
  medium,

  /// iPad landscape. Three columns: categories, configuration, order.
  expanded;

  bool get isCompact => this == FormFactor.compact;
  bool get isMedium => this == FormFactor.medium;
  bool get isExpanded => this == FormFactor.expanded;

  /// True when the layout has room for a persistent order pane, i.e. the
  /// running order never has to be opened as a sheet.
  bool get hasSideOrderPane => this != FormFactor.compact;
}

abstract final class KuboBreakpoints {
  /// iPhone 16 Plus is 430pt wide; every current iPhone sits below this.
  static const double medium = 600;

  /// iPad portrait is 768–834pt; landscape is 1024pt and up.
  static const double expanded = 900;

  static FormFactor fromWidth(double width) {
    if (width >= expanded) return FormFactor.expanded;
    if (width >= medium) return FormFactor.medium;
    return FormFactor.compact;
  }
}

/// Makes the current [FormFactor] available to the widget tree.
///
/// Screens read this instead of measuring `MediaQuery` themselves, so a pane
/// can be told it is "compact" even on an iPad when it genuinely is narrow.
class LayoutScope extends InheritedWidget {
  const LayoutScope({
    required this.formFactor,
    required this.width,
    required super.child,
    super.key,
  });

  final FormFactor formFactor;
  final double width;

  static LayoutScope of(BuildContext context) {
    final LayoutScope? scope = context
        .dependOnInheritedWidgetOfExactType<LayoutScope>();
    assert(scope != null, 'No LayoutScope found. Wrap the app in AppLayout.');
    return scope!;
  }

  @override
  bool updateShouldNotify(LayoutScope oldWidget) =>
      oldWidget.formFactor != formFactor || oldWidget.width != width;
}

/// Measures the space it is given and publishes a [LayoutScope] for it.
class AppLayout extends StatelessWidget {
  const AppLayout({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final double width = constraints.maxWidth.isFinite
          ? constraints.maxWidth
          : MediaQuery.sizeOf(context).width;
      return LayoutScope(
        formFactor: KuboBreakpoints.fromWidth(width),
        width: width,
        child: child,
      );
    },
  );
}

extension FormFactorContext on BuildContext {
  FormFactor get formFactor => LayoutScope.of(this).formFactor;
  double get layoutWidth => LayoutScope.of(this).width;
}

/// Picks a builder for the current form factor.
///
/// [medium] and [expanded] fall back to the next smaller builder when not
/// supplied, so a screen only has to describe the layouts it actually differs
/// on.
class ResponsiveBuilder extends StatelessWidget {
  const ResponsiveBuilder({
    required this.compact,
    this.medium,
    this.expanded,
    super.key,
  });

  final WidgetBuilder compact;
  final WidgetBuilder? medium;
  final WidgetBuilder? expanded;

  @override
  Widget build(BuildContext context) => switch (context.formFactor) {
    FormFactor.expanded => (expanded ?? medium ?? compact)(context),
    FormFactor.medium => (medium ?? compact)(context),
    FormFactor.compact => compact(context),
  };
}
