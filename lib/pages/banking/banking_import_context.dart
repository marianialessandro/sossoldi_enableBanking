import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/banking_ui_provider.dart';
import '../../services/banking/banking_reference.dart';
import 'widgets/bank_sync_context_dialog.dart';

Future<Map<String, String>?> collectBankImportContext(
  BuildContext context,
  List<String> headers,
) {
  if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) {
    return Future.value(null);
  }
  return showDialog<Map<String, String>>(
    context: context,
    builder: (_) => BankSyncContextDialog(headers: headers, importing: true),
  );
}

Future<void> resumeBankImport(
  BuildContext context,
  WidgetRef ref, {
  int? connectionId,
  BankingAccountReference? accountReference,
}) async {
  if (!context.mounted) return;
  await ref
      .read(connectBankFlowProvider.notifier)
      .resumeImport(
        connectionId: connectionId,
        accountReference: accountReference,
        collectContext: (headers) => collectBankImportContext(context, headers),
      );
}
