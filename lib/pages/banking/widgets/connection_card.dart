import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../constants/style.dart';
import '../../../model/bank_account.dart';
import '../../../model/bank_connection.dart';
import '../../../providers/accounts_provider.dart';
import '../../../providers/banking_ui_provider.dart';
import '../../../ui/device.dart';
import '../../../ui/extensions.dart';
import '../../../ui/snack_bars/snack_bar.dart';
import '../../../ui/widgets/default_card.dart';
import '../../../ui/widgets/rounded_icon.dart';
import 'confirm_disconnect_dialog.dart';
import 'bank_sync_context_dialog.dart';
import '../banking_import_context.dart';

/// One linked bank: how many accounts it feeds, until when the consent is valid and the actions available on it.
class ConnectionCard extends ConsumerStatefulWidget {
  const ConnectionCard({required this.connection, super.key});

  final BankConnection connection;

  @override
  ConsumerState<ConnectionCard> createState() => _ConnectionCardState();
}

class _ConnectionCardState extends ConsumerState<ConnectionCard> {
  bool _syncing = false;
  bool _resuming = false;
  final _localFocus = FocusNode(debugLabel: 'Disconnect locally');
  final _revokeFocus = FocusNode(debugLabel: 'Disconnect and revoke');
  @override
  void dispose() {
    _localFocus.dispose();
    _revokeFocus.dispose();
    super.dispose();
  }

  Future<void> _resume() async {
    if (_resuming) return;
    setState(() => _resuming = true);
    try {
      await resumeBankImport(context, ref, connectionId: connection.id);
    } finally {
      if (mounted) setState(() => _resuming = false);
    }
  }

  BankConnection get connection => widget.connection;

  Future<void> _confirmDisconnect({required bool local}) async {
    final expected = connection;
    (local ? _localFocus : _revokeFocus).requestFocus();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => local
          ? ConfirmLocalDisconnectDialog(connection: expected)
          : ConfirmDisconnectDialog(connection: expected),
    );
    if (confirmed != true || !mounted) return;
    final flow = ref.read(connectBankFlowProvider.notifier);
    if (local) {
      await flow.disconnectLocally(expected);
    } else {
      await flow.disconnect(expected);
    }
  }

  Future<void> _reconnect(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(connectBankFlowProvider.notifier).reconnect(connection);
    } on EnableBankingException catch (e) {
      if (!context.mounted) return;
      showSnackBar(context, message: bankingErrorMessage(e));
    } on EnableBankingAuthException catch (e) {
      if (!context.mounted) return;
      showSnackBar(context, message: bankingErrorMessage(e));
    } catch (e) {
      if (context.mounted) {
        showSnackBar(context, message: bankingErrorMessage(e));
      }
    }
  }

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    setState(() => _syncing = true);
    try {
      final flow = ref.read(connectBankFlowProvider.notifier);
      final requiredHeaders = await flow.requiredSyncHeaders(connection);
      if (!context.mounted) return;
      Map<String, String> headers = const {};
      if (requiredHeaders.isNotEmpty) {
        final values = await showDialog<Map<String, String>>(
          context: context,
          builder: (_) => BankSyncContextDialog(headers: requiredHeaders),
        );
        if (values == null || !context.mounted) return;
        headers = values;
      }
      final count = await flow.syncConnection(connection, psuHeaders: headers);
      if (!context.mounted) return;
      showSnackBar(context, message: bankSyncMessage(count));
    } on EnableBankingException catch (e) {
      if (!context.mounted) return;
      showSnackBar(context, message: bankingErrorMessage(e));
    } on EnableBankingAuthException catch (e) {
      if (!context.mounted) return;
      showSnackBar(context, message: bankingErrorMessage(e));
    } catch (e) {
      if (context.mounted) {
        showSnackBar(context, message: bankingErrorMessage(e));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final recovery = ref
        .watch(connectBankFlowProvider)
        .recoveryActions
        .where((item) => item.concerns(connection));
    final action = recovery.isEmpty ? null : recovery.last;
    final busy = action?.status == BankRecoveryActionStatus.running;
    final configured = ref.watch(enableBankingSettingsProvider).value;
    final canRevoke = configured?.appId == connection.applicationId;
    final accounts = ref.watch(accountsProvider).value ?? const <BankAccount>[];
    final linked = accounts
        .where((account) => account.ebConnectionId == connection.id)
        .toList();
    final syncStatus = ref.watch(
      bankConnectionSyncStatusProvider(connection.id!),
    );
    final isExpired =
        connection.status == BankConnectionStatus.expired ||
        connection.status == BankConnectionStatus.reauthRequired ||
        (connection.validUntil != null &&
            !connection.validUntil!.isAfter(
              ref.read(bankingClockProvider)().toUtc(),
            ));

    return DefaultCard(
      onTap: null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: Sizes.md,
            children: [
              RoundedIcon(
                icon: Icons.account_balance,
                backgroundColor: Theme.of(context).colorScheme.secondary,
                size: 30,
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    connection.institutionName,
                    style: Theme.of(context).textTheme.titleLarge!.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  Text(
                    "${bankAccountCount(linked.length)} · consent valid until "
                    "${(connection.pendingValidUntil ?? connection.validUntil)?.formatEDMY() ?? '—'}",
                    style: Theme.of(context).textTheme.bodySmall!.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
              Text(
                isExpired
                    ? "RECONNECT"
                    : switch (connection.status) {
                        BankConnectionStatus.awaitingImport =>
                          'Ready to import',
                        BankConnectionStatus.revocationPending =>
                          'Disconnecting',
                        BankConnectionStatus.active => 'Connected',
                        BankConnectionStatus.authorizing => 'Awaiting consent',
                        _ => 'Reconnect required',
                      },
                style: Theme.of(context).textTheme.labelLarge!.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
          syncStatus.when(
            data: (summary) => !bankSyncNeedsAttention(summary)
                ? const SizedBox.shrink()
                : Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Sizes.md),
                      child: Text(bankSyncMessage(summary)),
                    ),
                  ),
            loading: () => const SizedBox.shrink(),
            error: (_, _) =>
                const Text('Could not load the last sync result. Try again.'),
          ),
          if (!canRevoke)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Sizes.lg),
              child: Text(
                bankRecoveryCredentialsMessage,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          if (action != null &&
              action.status != BankRecoveryActionStatus.applied &&
              action.status != BankRecoveryActionStatus.stale)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Sizes.lg),
                child: Text(
                  action.message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          if (action?.status == BankRecoveryActionStatus.failed)
            TextButton(
              onPressed:
                  busy ||
                      (!canRevoke &&
                          action?.kind == BankRecoveryActionKind.revoke)
                  ? null
                  : () => _confirmDisconnect(
                      local: action?.kind == BankRecoveryActionKind.local,
                    ),
              child: const Text('Try again'),
            ),
          TextButton(
            focusNode: _localFocus,
            onPressed: busy ? null : () => _confirmDisconnect(local: true),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            child: const Text('Disconnect locally'),
          ),
          const SizedBox(height: Sizes.lg),
          const Divider(height: 1, color: grey2),
          if (connection.pendingRemoteConnectionId != null)
            TextButton(
              onPressed: _resuming ? null : _resume,
              child: const Text("CONTINUE IMPORT"),
            ),
          if (isExpired)
            Padding(
              padding: const EdgeInsets.only(top: Sizes.md),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _reconnect(context, ref),
                  child: const Text("RECONNECT"),
                ),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  "Last synced: ${_lastSyncLabel(linked)}",
                  style: Theme.of(context).textTheme.bodySmall!.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              _syncing
                  ? const Padding(
                      padding: EdgeInsets.all(Sizes.sm),
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      tooltip: 'Sync ${connection.institutionName}',
                      icon: const Icon(Icons.refresh),
                      onPressed:
                          isExpired ||
                              connection.status != BankConnectionStatus.active
                          ? null
                          : () => _sync(context, ref),
                    ),
              IconButton(
                focusNode: _revokeFocus,
                tooltip: 'Disconnect and revoke ${connection.institutionName}',
                icon: Icon(
                  Icons.link_off,
                  color: Theme.of(context).colorScheme.error,
                ),
                onPressed: busy || !canRevoke
                    ? null
                    : () => _confirmDisconnect(local: false),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Latest successful server-timed sync across the accounts fed by this connection.
  String _lastSyncLabel(List<BankAccount> linked) {
    final syncs = linked.map((account) => account.lastSyncAt).nonNulls.toList()
      ..sort();
    return syncs.isEmpty ? "never" : syncs.last.formatEDMY();
  }
}
