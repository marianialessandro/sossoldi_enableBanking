import 'dart:io';

import 'package:flutter/material.dart';

/// Collects only the bank-declared context for one interactive request, without persisting its values.
class BankSyncContextDialog extends StatefulWidget {
  final List<String> headers;
  final bool importing;
  const BankSyncContextDialog({
    required this.headers,
    this.importing = false,
    super.key,
  });

  @override
  State<BankSyncContextDialog> createState() => _BankSyncContextDialogState();
}

class _BankSyncContextDialogState extends State<BankSyncContextDialog> {
  final form = GlobalKey<FormState>();
  late final controllers = {
    for (final header in widget.headers) header: TextEditingController(),
  };
  late final nodes = {for (final header in widget.headers) header: FocusNode()};
  late final fieldKeys = {
    for (final header in widget.headers)
      header: GlobalKey<FormFieldState<String>>(),
  };

  String label(String header) => switch (header.toLowerCase()) {
    'psu-ip-address' => 'Your IP address',
    'psu-user-agent' => 'Browser or app details',
    _ =>
      header
          .replaceFirst(RegExp(r'^psu-', caseSensitive: false), '')
          .replaceAll('-', ' '),
  };

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    for (final node in nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Additional details required'),
    content: Form(
      key: form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.importing
                ? 'Your bank requires these details to load your accounts. They are sent through Enable Banking only when you continue. The values are not saved.'
                : 'Your bank requires these details for this refresh. They are sent through Enable Banking only when you continue. The values are not saved.',
          ),
          for (final entry in controllers.entries)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: TextFormField(
                key: fieldKeys[entry.key],
                focusNode: nodes[entry.key],
                controller: entry.value,
                decoration: InputDecoration(labelText: label(entry.key)),
                autocorrect: false,
                validator: (raw) {
                  final value = raw?.trim() ?? '';
                  if (value.isEmpty ||
                      (raw ?? '').contains(RegExp(r'[\r\n]'))) {
                    return 'Enter a value for this request';
                  }
                  if (entry.key.toLowerCase() == 'psu-ip-address' &&
                      InternetAddress.tryParse(value) == null) {
                    return 'Enter a valid IP address';
                  }
                  return null;
                },
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, {
              for (final entry in controllers.entries)
                entry.key: entry.value.text.trim(),
            });
          } else {
            final first = fieldKeys.entries.firstWhere(
              (entry) => entry.value.currentState?.hasError == true,
            );
            nodes[first.key]!.requestFocus();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final fieldContext = first.value.currentContext;
              if (mounted && fieldContext != null) {
                Scrollable.ensureVisible(fieldContext);
              }
            });
          }
        },
        child: const Text('Continue'),
      ),
    ],
  );
}
