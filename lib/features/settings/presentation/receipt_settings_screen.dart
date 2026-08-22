import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/entities/business_settings.dart';

/// What goes on the receipt, and the picture at the bottom of it.
///
/// The image is stored inside the database rather than as a file on the
/// device, so it travels with every backup and restores with them. That means
/// it has to stay small, and it is resized on the way in.
class ReceiptSettingsScreen extends ConsumerStatefulWidget {
  const ReceiptSettingsScreen({super.key});

  @override
  ConsumerState<ReceiptSettingsScreen> createState() =>
      _ReceiptSettingsScreenState();
}

class _ReceiptSettingsScreenState extends ConsumerState<ReceiptSettingsScreen> {
  /// Wide enough to stay crisp on an 80mm roll at 300dpi, small enough that
  /// the database does not grow by a megabyte.
  static const int _maxWidth = 600;

  Uint8List? _footer;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final String? stored = await ref
        .read(settingsRepositoryProvider)
        .readRaw(SettingKeys.receiptFooterImage);
    if (!mounted) return;
    setState(() {
      _footer = (stored == null || stored.isEmpty)
          ? null
          : base64Decode(stored);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final BusinessSettings settings = ref.watch(settingsControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Receipt')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KuboSpacing.lg,
              KuboSpacing.lg,
              KuboSpacing.lg,
              0,
            ),
            child: Text('Footer picture', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KuboSpacing.lg,
              KuboSpacing.xs,
              KuboSpacing.lg,
              KuboSpacing.md,
            ),
            child: Text(
              'Printed at the bottom of every receipt — a QR code to your '
              'socials or a review page works well. Keep it square-ish and '
              'high contrast; receipts print in black and white.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(KuboSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
              child: _FooterPreview(image: _footer),
            ),
          Padding(
            padding: const EdgeInsets.all(KuboSpacing.lg),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _pick,
                    icon: const Icon(Icons.image_outlined),
                    label: Text(_footer == null ? 'CHOOSE' : 'REPLACE'),
                  ),
                ),
                if (_footer != null) ...<Widget>[
                  const SizedBox(width: KuboSpacing.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _remove,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('REMOVE'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KuboSpacing.lg,
              KuboSpacing.lg,
              KuboSpacing.lg,
              0,
            ),
            child: Text('Tax', style: theme.textTheme.titleMedium),
          ),
          SwitchListTile(
            value: settings.vatRegistered,
            title: const Text('The shop is VAT-registered'),
            subtitle: Text(
              settings.vatRegistered
                  ? 'Menu prices include 12% VAT, and a Senior Citizen or PWD '
                        'sale is VAT-exempt: the VAT comes off before the 20%.'
                  : 'No VAT is charged or shown. A Senior Citizen or PWD sale '
                        'is simply 20% off the menu price.',
            ),
            onChanged: (bool value) => ref
                .read(settingsControllerProvider.notifier)
                .update(settings.copyWith(vatRegistered: value)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KuboSpacing.lg,
              0,
              KuboSpacing.lg,
              KuboSpacing.lg,
            ),
            child: Text(
              'Registration depends on turnover, not on preference. Below the '
              '₱3,000,000 annual threshold a business is not VAT-registered, '
              'and this should stay off. Getting it wrong changes what every '
              'discounted customer pays, so check before switching it.',
              style: theme.textTheme.bodySmall,
            ),
          ),

          const Divider(),
          SwitchListTile(
            value: settings.deliveryFeeEnabled,
            title: const Text('Offer a delivery fee'),
            subtitle: const Text(
              'Adds a delivery button beside the discount on the POS.',
            ),
            onChanged: (bool value) => ref
                .read(settingsControllerProvider.notifier)
                .update(settings.copyWith(deliveryFeeEnabled: value)),
          ),
        ],
      ),
    );
  }

  Future<void> _pick() async {
    setState(() => _busy = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final XFile? picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
      );
      if (picked == null) return;

      final img.Image? decoded = img.decodeImage(await picked.readAsBytes());
      if (decoded == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('That file is not a picture.')),
        );
        return;
      }

      // Resized on the way in rather than on the way out: the database keeps
      // one small copy, and every receipt printed from it is fast.
      final img.Image sized = decoded.width > _maxWidth
          ? img.copyResize(decoded, width: _maxWidth)
          : decoded;
      final Uint8List png = Uint8List.fromList(img.encodePng(sized));

      await ref
          .read(settingsRepositoryProvider)
          .writeRaw(SettingKeys.receiptFooterImage, base64Encode(png));
      if (mounted) setState(() => _footer = png);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    await ref
        .read(settingsRepositoryProvider)
        .writeRaw(SettingKeys.receiptFooterImage, '');
    if (mounted) setState(() => _footer = null);
  }
}

class _FooterPreview extends StatelessWidget {
  const _FooterPreview({required this.image});

  final Uint8List? image;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      height: 160,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(KuboRadius.md),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: image == null
          ? Text('Nothing yet', style: theme.textTheme.bodySmall)
          : Padding(
              padding: const EdgeInsets.all(KuboSpacing.md),
              // On white, because that is the paper it will be printed on.
              child: ColoredBox(
                color: const Color(0xFFFFFFFF),
                child: Image.memory(image!, fit: BoxFit.contain),
              ),
            ),
    );
  }
}
