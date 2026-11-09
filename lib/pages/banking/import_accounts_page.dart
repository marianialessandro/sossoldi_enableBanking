import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants/constants.dart';
import '../../constants/style.dart';
import '../../providers/banking_ui_provider.dart';
import '../../model/bank_connection.dart';
import '../../services/banking/banking_account.dart';
import '../../services/banking/banking_account_import_result.dart';
import '../../services/banking/banking_reference.dart';
import '../../ui/device.dart';
import '../../ui/snack_bars/snack_bar.dart';
import '../../ui/widgets/alert_dialog.dart';
import '../../ui/widgets/default_container.dart';
import 'widgets/account_import_tile.dart';
import 'banking_import_context.dart';

/// How the user wants one bank account to land in the app.
class _ImportDraft {
  _ImportDraft({required this.account, required this.nameController});

  BankingAccount account;
  final TextEditingController nameController;
  bool selected = true;
  String symbol = accountIconList.keys.first;
  int color = 0;
}

/// Last leg of the connect flow: pick which accounts of the freshly linked bank become app accounts, and how they look.
class ImportAccountsPage extends ConsumerStatefulWidget {
  const ImportAccountsPage({super.key});

  @override
  ConsumerState<ImportAccountsPage> createState() => _ImportAccountsPageState();
}

class _ImportAccountsPageState extends ConsumerState<ImportAccountsPage> {
  final List<_ImportDraft> drafts = [];
  bool importing = false;
  BankConnection? expectedStaging;

  @override
  void initState() {
    super.initState();

    final flow = ref.read(connectBankFlowProvider);
    expectedStaging = flow.connection;
    _reconcile(flow.importable, reset: true);
  }

  void _reconcile(List<BankingAccount> accounts, {required bool reset}) {
    final previous = {
      for (final draft in drafts) draft.account.reference: draft,
    };
    final next = <_ImportDraft>[];
    for (final account in accounts) {
      final retained = reset ? null : previous.remove(account.reference);
      if (retained != null) {
        retained.account = account;
        next.add(retained);
      } else {
        next.add(
          _ImportDraft(
            account: account,
            nameController: TextEditingController(
              text: account.name ?? account.product ?? 'Account',
            ),
          ),
        );
      }
    }
    final removed = reset ? drafts.toList() : previous.values.toList();
    drafts
      ..clear()
      ..addAll(next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final draft in removed) {
        draft.nameController.dispose();
      }
    });
  }

  @override
  void dispose() {
    for (final draft in drafts) {
      draft.nameController.dispose();
    }
    super.dispose();
  }

  Future<void> _import() async {
    final selected = drafts.where((draft) => draft.selected).toList();
    final expected = expectedStaging;
    if (selected.isEmpty || expected == null) return;

    setState(() => importing = true);
    try {
      final syncResult = await ref
          .read(connectBankFlowProvider.notifier)
          .importAccounts(
            [
              for (final draft in selected)
                BankAccountImportSelection(
                  expectedStaging: expected,
                  account: draft.account,
                  name: draft.nameController.text.trim().isEmpty
                      ? "Account"
                      : draft.nameController.text.trim(),
                  symbol: draft.symbol,
                  color: draft.color,
                ),
            ],
            collectContext: (headers) =>
                collectBankImportContext(context, headers),
          );
      if (!mounted) return;

      // The snack bar goes through the root messenger: this route is about to be popped, so its own context cannot show anything.
      Navigator.popUntil(context, ModalRoute.withName('/connect-bank'));
      showRootSnackBar(
        message:
            "${bankAccountCount(selected.length)} imported. "
            "${bankSyncMessage(syncResult)}",
      );
    } on ConnectBankFlowException catch (e) {
      if (!mounted) return;
      showErrorDialog(context, e.message);
    } catch (e) {
      if (!mounted) return;
      showErrorDialog(context, 'Could not import the accounts. Try again.');
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(connectBankFlowProvider, (previous, next) {
      final reset =
          previous?.connection == null ||
          next.connection == null ||
          !previous!.connection!.sameLifecycle(next.connection!);
      setState(() {
        expectedStaging = next.connection;
        _reconcile(next.importable, reset: reset);
      });
    });
    final flow = ref.watch(connectBankFlowProvider);
    final connection = flow.connection;
    final selectedCount = drafts.where((draft) => draft.selected).length;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Import accounts'),
      ),
      persistentFooterDecoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.15),
            blurRadius: 5.0,
            offset: const Offset(0, -1.0),
          ),
        ],
      ),
      persistentFooterButtons: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Sizes.sm,
            Sizes.xs,
            Sizes.sm,
            Sizes.sm,
          ),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              boxShadow: [defaultShadow],
              borderRadius: BorderRadius.circular(Sizes.borderRadius),
            ),
            child: ElevatedButton(
              onPressed: selectedCount == 0 || importing || !flow.canImport
                  ? null
                  : _import,
              child: const Text("IMPORT SELECTED"),
            ),
          ),
        ),
      ],
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: Sizes.sm),
        physics: const BouncingScrollPhysics(),
        child: Column(
          children: [
            DefaultContainer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Select the accounts to import",
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  Text(
                    "${connection?.institutionName ?? 'Bank'} · "
                    "${bankAccountCount(flow.outcomes.isEmpty ? drafts.length : flow.outcomes.length)}",
                    style: Theme.of(context).textTheme.bodySmall!.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            if (flow.loading)
              Semantics(
                liveRegion: true,
                child: const Padding(
                  padding: EdgeInsets.all(Sizes.lg),
                  child: Column(
                    children: [
                      CircularProgressIndicator(),
                      Text('Loading bank accounts…'),
                    ],
                  ),
                ),
              ),
            if (!flow.loading &&
                flow.importStatus != BankingImportStatus.ready &&
                flow.importStatus != BankingImportStatus.idle)
              DefaultContainer(
                child: Semantics(
                  liveRegion: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_statusMessage(flow)),
                      if (flow.importStatus == BankingImportStatus.terminal)
                        if (flow.failureScope ==
                                BankingImportFailureScope.application ||
                            flow.outcomes.any(
                              (item) =>
                                  item.scope ==
                                  BankingImportFailureScope.application,
                            ))
                          TextButton(
                            onPressed: () => Navigator.of(
                              context,
                            ).pushNamed('/enable-banking-setup'),
                            child: const Text('Bank sync settings'),
                          )
                        else
                          TextButton(
                            onPressed: connection == null
                                ? null
                                : () => _reconnect(connection),
                            child: const Text('RECONNECT'),
                          )
                      else
                        TextButton(
                          onPressed: () => _retry(),
                          child: const Text('Try again'),
                        ),
                      if (flow.importStatus == BankingImportStatus.terminal &&
                          flow.failureScope == null)
                        TextButton(
                          onPressed: () => Navigator.of(
                            context,
                          ).pushNamed('/enable-banking-setup'),
                          child: const Text('Bank sync settings'),
                        ),
                    ],
                  ),
                ),
              ),
            if (flow.outcomes.isNotEmpty)
              for (var index = 0; index < flow.outcomes.length; index++)
                if (flow.importStatus != BankingImportStatus.terminal &&
                    flow.outcomes[index].account != null)
                  _tile(
                    drafts.firstWhere(
                      (draft) =>
                          draft.account.reference ==
                          flow.outcomes[index].account!.reference,
                    ),
                    flow.outcomes[index].balance,
                    balanceUnavailable:
                        flow.outcomes[index].code == 'balance_unavailable',
                  )
                else
                  _unavailable(flow.outcomes[index], index, flow.loading)
            else
              for (final draft in drafts) _tile(draft, null),
          ],
        ),
      ),
    );
  }

  Future<void> _retry({BankingAccountReference? reference}) => resumeBankImport(
    context,
    ref,
    connectionId: expectedStaging?.id,
    accountReference: reference,
  );

  Future<void> _reconnect(BankConnection connection) async {
    try {
      await ref.read(connectBankFlowProvider.notifier).reconnect(connection);
    } catch (error) {
      if (mounted) showErrorDialog(context, bankingErrorMessage(error));
    }
  }

  String _statusMessage(
    ConnectBankFlowState flow,
  ) => switch (flow.importStatus) {
    BankingImportStatus.empty =>
      'No accounts returned\nThe bank did not return any accounts. Try again or check with your bank.',
    BankingImportStatus.partial =>
      'Some accounts could not be loaded. You can import the available accounts or retry.',
    BankingImportStatus.cancelled =>
      'Account loading was cancelled. Try again when you are ready.',
    BankingImportStatus.manualContextRequired =>
      'Additional details are required to load your accounts. Try again to continue.',
    BankingImportStatus.unavailable => 'Not available for import',
    BankingImportStatus.pending =>
      'Your bank connection is not ready yet. Try again.',
    BankingImportStatus.obsolete =>
      'The bank connection changed. Reload the accounts before importing.',
    BankingImportStatus.terminal =>
      (flow.failureScope == BankingImportFailureScope.application ||
              flow.outcomes.any(
                (item) => item.scope == BankingImportFailureScope.application,
              ))
          ? 'Check your Enable Banking credentials in Bank sync settings before retrying.'
          : 'This bank connection is no longer valid. Reconnect the bank.',
    _ => 'No accounts could be loaded. Check your connection and try again.',
  };

  Widget _unavailable(
    BankingAccountImportOutcome outcome,
    int index,
    bool loading,
  ) {
    final descriptor = outcome.descriptor;
    return DefaultContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            descriptor.name ?? descriptor.product ?? 'Account ${index + 1}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text(
            [
              AccountImportTile.maskIban(descriptor.iban),
              if (descriptor.currency != null) descriptor.currency!,
            ].join(' · '),
          ),
          Text(
            descriptor.reference == null
                ? 'Not available for import'
                : 'This account could not be loaded. Try again.',
          ),
          if (descriptor.reference == null)
            const Text(
              'The bank did not provide the details needed to import this account. Check with your bank.',
            ),
          if (descriptor.reference != null &&
              outcome.scope != BankingImportFailureScope.consent &&
              outcome.scope != BankingImportFailureScope.application)
            TextButton(
              onPressed: loading
                  ? null
                  : () => _retry(reference: descriptor.reference),
              child: const Text('Try again'),
            ),
        ],
      ),
    );
  }

  Widget _tile(
    _ImportDraft draft,
    num? balance, {
    bool balanceUnavailable = false,
  }) => Column(
    children: [
      AccountImportTile(
        key: ValueKey(draft.account.reference),
        balance: AsyncData(balance),
        account: draft.account,
        selected: draft.selected,
        nameController: draft.nameController,
        symbol: draft.symbol,
        color: draft.color,
        onSelectedChanged: (value) => setState(() => draft.selected = value),
        onIconChanged: (icon) => setState(() => draft.symbol = icon),
        onColorChanged: (color) => setState(() => draft.color = color),
      ),
      if (balanceUnavailable)
        DefaultContainer(
          child: Column(
            children: [
              const Text('The account balance could not be loaded. Try again.'),
              TextButton(
                onPressed: ref.read(connectBankFlowProvider).loading
                    ? null
                    : () => _retry(reference: draft.account.reference),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
    ],
  );
}
