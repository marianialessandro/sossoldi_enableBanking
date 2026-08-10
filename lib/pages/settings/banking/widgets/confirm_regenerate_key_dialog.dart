import 'package:flutter/material.dart';

import '../../../../ui/device.dart';
import '../../../../ui/widgets/native_alert_dialog.dart';

class ConfirmRegenerateKeyDialog extends StatelessWidget {
  final VoidCallback onPressed;

  const ConfirmRegenerateKeyDialog({required this.onPressed, super.key});

  @override
  Widget build(BuildContext context) {
    return AdaptiveDialog(
      title: const Text('Generate a new key?'),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: Sizes.md,
        children: [
          Text(
            'A private key is already stored on this device. Generating a '
            'new one replaces it.',
          ),
          Text(
            'The certificate already uploaded to Enable Banking will no '
            "longer match: you'll need to upload the new certificate and "
            'may get a new app_id.',
          ),
        ],
      ),
      actions: [
        AdaptiveDialogAction(
          child: const Text('Cancel'),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
        AdaptiveDialogAction(
          child: const Text('Generate'),
          isDestructiveAction: true,
          onPressed: onPressed,
        ),
      ],
    );
  }
}
