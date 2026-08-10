import 'package:flutter/material.dart';

import '../../../model/bank_connection.dart';
import '../../../ui/device.dart';
import '../../../ui/widgets/native_alert_dialog.dart';

class ConfirmDisconnectDialog extends StatelessWidget {
  final BankConnection connection;
  final VoidCallback onPressed;

  const ConfirmDisconnectDialog({
    required this.connection,
    required this.onPressed,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return AdaptiveDialog(
      title: const Text('Disconnect bank'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: Sizes.md,
        children: [
          Text(
            'Are you sure you want to disconnect '
            '"${connection.aspspName}"?',
          ),
          const Text(
            'Imported accounts and their transactions are kept as manual '
            'accounts.',
          ),
          const SizedBox(height: Sizes.md),
          const Text('The consent will be revoked.'),
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
          child: const Text('Disconnect'),
          isDestructiveAction: true,
          onPressed: onPressed,
        ),
      ],
    );
  }
}
