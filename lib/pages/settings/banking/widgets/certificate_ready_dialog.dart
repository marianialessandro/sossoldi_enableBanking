import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../ui/device.dart';
import '../../../../ui/snack_bars/snack_bar.dart';
import '../../../../ui/widgets/native_alert_dialog.dart';

class CertificateReadyDialog extends StatelessWidget {
  const CertificateReadyDialog({
    required this.certificatePem,
    required this.onSaveToFile,
    super.key,
  });

  final String certificatePem;
  final VoidCallback onSaveToFile;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: certificatePem));
    if (context.mounted) {
      showSnackBar(context, message: 'Certificate copied');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveDialog(
      title: const Text('Certificate ready'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: Sizes.md,
        children: [
          const Text(
            'Copy or save this certificate, then upload it to your Enable '
            'Banking application to get your app_id.',
          ),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 140),
            padding: const EdgeInsets.all(Sizes.sm),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Sizes.borderRadiusSmall),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                certificatePem,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall!.copyWith(fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      ),
      actions: [
        AdaptiveDialogAction(
          child: const Text('Copy'),
          onPressed: () => _copy(context),
        ),
        AdaptiveDialogAction(
          child: const Text('Save to file'),
          onPressed: onSaveToFile,
        ),
        AdaptiveDialogAction(
          child: const Text('Done'),
          isDefaultAction: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
