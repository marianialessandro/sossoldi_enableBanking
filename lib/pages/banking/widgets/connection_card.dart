import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../constants/style.dart';
import '../../../model/bank_account.dart';
import '../../../model/bank_connection.dart';
import '../../../providers/accounts_provider.dart';
import '../../../providers/banking_provider.dart';
import '../../../services/banking/enable_banking_auth.dart';
import '../../../services/banking/enable_banking_exception.dart';
import '../../../services/banking/models/aspsp.dart';
import '../../../ui/device.dart';
import '../../../ui/extensions.dart';
import '../../../ui/snack_bars/snack_bar.dart';
import '../../../ui/widgets/default_card.dart';
import '../../../ui/widgets/rounded_icon.dart';
import 'confirm_disconnect_dialog.dart';

/// One linked bank: how many accounts it feeds, until when the consent is
/// valid and the actions available on it.
class ConnectionCard extends ConsumerStatefulWidget {
  const ConnectionCard({required this.connection, super.key});

  final BankConnection connection;

  @override
  ConsumerState<ConnectionCard> createState() => _ConnectionCardState();
}

class _ConnectionCardState extends ConsumerState<ConnectionCard> {
  bool _syncing = false;
  bool _disconnecting = false;

  BankConnection get connection => widget.connection;

  Future<void> _disconnect(BuildContext context, WidgetRef ref) async {
    setState(() => _disconnecting = true);
    try {
      await ref.read(connectBankFlowProvider.notifier).disconnect(connection);
      if (!context.mounted) return;
      showSnackBar(context, message: "Bank disconnected");
    } on EnableBankingAuthException catch (e) {
      if (!context.mounted) return;
      showSnackBar(context, message: e.message);
    } catch (e) {
      if (!context.mounted) return;
      showSnackBar(context, message: 'Could not disconnect the bank');
    } finally {
      if (mounted) setState(() => _disconnecting = false);
    }
  }

  Future<void> _reconnect(BuildContext context, WidgetRef ref) async {
    try {
      final url = await ref
          .read(connectBankFlowProvider.notifier)
          .startConnection(
            Aspsp(name: connection.aspspName, country: connection.aspspCountry),
            reconnecting: connection,
          );
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } on EnableBankingException catch (e) {
      if (!context.mounted) return;
      showSnackBar(context, message: e.message ?? 'Authorization failed');
    } on EnableBankingAuthException catch (e) {
      if (!context.mounted) return;
      showSnackBar(context, message: e.message);
    }
  }

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    setState(() => _syncing = true);
    try {
      final count = await ref
          .read(connectBankFlowProvider.notifier)
          .syncConnection(connection);
      if (!context.mounted) return;
      showSnackBar(context, message: "Synced $count transactions");
    } on EnableBankingException catch (e) {
      if (!context.mounted) return;
      showSnackBar(context, message: e.message ?? 'Sync failed');
    } on EnableBankingAuthException catch (e) {
      if (!context.mounted) return;
      showSnackBar(context, message: e.message);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider).value ?? const <BankAccount>[];
    final linked = accounts
        .where((account) => account.ebConnectionId == connection.id)
        .toList();
    final isExpired =
        connection.status == BankConnectionStatus.expired ||
        connection.validUntil.isBefore(DateTime.now());

    return DefaultCard(
      onTap: null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            spacing: Sizes.md,
            children: [
              RoundedIcon(
                icon: Icons.account_balance,
                backgroundColor: Theme.of(context).colorScheme.secondary,
                size: 30,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connection.aspspName,
                      style: Theme.of(context).textTheme.titleLarge!.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    Text(
                      "${linked.length} accounts · valid until "
                      "${connection.validUntil.formatEDMY()}",
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall!.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                isExpired ? "EXPIRED" : connection.status.name.toUpperCase(),
                style: Theme.of(context).textTheme.labelLarge!.copyWith(
                  color: isExpired ? red : green,
                ),
              ),
            ],
          ),
          const SizedBox(height: Sizes.md),
          const Divider(height: 1, color: grey2),
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
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    "Last synced ${_lastSyncLabel(linked)}",
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
                        icon: const Icon(Icons.refresh),
                        onPressed: () => _sync(context, ref),
                      ),
                _disconnecting
                    ? const Padding(
                        padding: EdgeInsets.all(Sizes.sm),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.link_off, color: red),
                        onPressed: () => showDialog(
                          context: context,
                          builder: (dialogContext) => ConfirmDisconnectDialog(
                            connection: connection,
                            onPressed: () {
                              Navigator.of(dialogContext).pop();
                              _disconnect(context, ref);
                            },
                          ),
                        ),
                      ),
              ],
            ),
        ],
      ),
    );
  }

  /// Most recent sync across the accounts fed by this connection.
  String _lastSyncLabel(List<BankAccount> linked) {
    final syncs = linked.map((account) => account.lastSyncAt).nonNulls.toList()
      ..sort();
    return syncs.isEmpty ? "never" : syncs.last.formatEDMY();
  }
}
