import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../domain/entities/app_user.dart';
import '../../../domain/services/sign_in_service.dart';
import '../../../shared/widgets/async_view.dart';

/// Who can use the app, and how much of it they see.
class StaffScreen extends ConsumerWidget {
  const StaffScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Who can sign in')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('ADD'),
      ),
      body: AsyncView<List<AppUser>>(
        value: ref.watch(usersProvider),
        builder: (BuildContext context, List<AppUser> users) => ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(KuboSpacing.lg),
              child: Text(
                users.isEmpty
                    ? 'Nobody is set up yet, so the app is open: whoever holds '
                          'the device sees everything. Add yourself as the '
                          'owner, then add your barista.'
                    : 'The owner sees the whole business. A barista sees the '
                          'till and the customers, and nothing about costs, '
                          'recipes or takings.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            for (final AppUser user in users)
              ListTile(
                leading: Icon(
                  user.role == UserRole.owner
                      ? Icons.workspace_premium_outlined
                      : Icons.local_cafe_outlined,
                ),
                title: Text(user.name),
                subtitle: Text(
                  user.role == UserRole.owner
                      ? 'Owner · everything'
                      : 'Barista · the POS only',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _edit(context, ref, user),
              ),
            const Divider(height: KuboSpacing.xxl),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
              child: Text(
                'What a PIN does, and does not, protect',
                style: theme.textTheme.titleSmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                KuboSpacing.lg,
                KuboSpacing.sm,
                KuboSpacing.lg,
                KuboSpacing.lg,
              ),
              child: Text(
                'This keeps your barista out of your books. It is not a lock '
                'against someone determined: a four-digit PIN is short, and '
                'anyone holding the phone — or a public link to the app — '
                'could work through it. Keep the device itself locked, and '
                'keep the web link private.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    AppUser? existing,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => _UserSheet(existing: existing),
    );
    ref.read(userRevisionProvider.notifier).bump();
  }
}

class _UserSheet extends ConsumerStatefulWidget {
  const _UserSheet({required this.existing});

  final AppUser? existing;

  @override
  ConsumerState<_UserSheet> createState() => _UserSheetState();
}

class _UserSheetState extends ConsumerState<_UserSheet> {
  late final TextEditingController _name;
  final TextEditingController _pin = TextEditingController();
  late UserRole _role;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _role = widget.existing?.role ?? UserRole.barista;
  }

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppUser? existing = widget.existing;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          KuboSpacing.lg,
          KuboSpacing.lg,
          KuboSpacing.lg,
          KuboSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              existing == null ? 'Add someone' : existing.name,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: KuboSpacing.lg),
            if (existing == null)
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
            if (existing == null) const SizedBox(height: KuboSpacing.md),
            if (existing == null)
              SegmentedButton<UserRole>(
                segments: const <ButtonSegment<UserRole>>[
                  ButtonSegment<UserRole>(
                    value: UserRole.owner,
                    label: Text('Owner'),
                  ),
                  ButtonSegment<UserRole>(
                    value: UserRole.barista,
                    label: Text('Barista'),
                  ),
                ],
                selected: <UserRole>{_role},
                onSelectionChanged: (Set<UserRole> value) =>
                    setState(() => _role = value.first),
              ),
            const SizedBox(height: KuboSpacing.md),
            TextField(
              controller: _pin,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 8,
              decoration: InputDecoration(
                labelText: existing == null ? 'PIN' : 'New PIN',
                helperText:
                    'At least ${SignInService.minPinLength} digits'
                    '${existing == null ? '' : '. Leave blank to keep the old one.'}',
              ),
            ),
            const SizedBox(height: KuboSpacing.md),
            if (existing != null)
              SwitchListTile(
                value: existing.isActive,
                contentPadding: EdgeInsets.zero,
                title: const Text('Can sign in'),
                onChanged: (bool value) => _run(
                  () => ref
                      .read(signInServiceProvider)
                      .setActive(userId: existing.id, isActive: value),
                ),
              ),
            const SizedBox(height: KuboSpacing.sm),
            FilledButton(onPressed: _save, child: const Text('SAVE')),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final AppUser? existing = widget.existing;
    await _run(() async {
      final SignInService service = ref.read(signInServiceProvider);
      if (existing == null) {
        await service.addUser(
          name: _name.text,
          role: _role,
          pin: _pin.text.trim(),
        );
      } else if (_pin.text.trim().isNotEmpty) {
        await service.setPin(userId: existing.id, pin: _pin.text.trim());
      }
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      ref.read(userRevisionProvider.notifier).bump();
      navigator.pop();
    } on AppException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}
