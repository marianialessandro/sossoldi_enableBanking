import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants/constants.dart';
import '../../constants/style.dart';
import '../../providers/banking_provider.dart';
import '../../services/banking/models/eb_account.dart';
import '../../ui/device.dart';
import '../../ui/snack_bars/snack_bar.dart';
import '../../ui/widgets/alert_dialog.dart';
import '../../ui/widgets/default_container.dart';
import 'widgets/account_import_tile.dart';

/// How the user wants one bank account to land in the app.
class _ImportDraft {
  _ImportDraft({required this.account, required this.nameController});

  final EbAccount account;
  final TextEditingController nameController;
  bool selected = true;
  String symbol = accountIconList.keys.first;
  int color = 0;
}

/// Last leg of the connect flow: pick which accounts of the freshly linked
/// bank become app accounts, and how they look.
class ImportAccountsPage extends ConsumerStatefulWidget {
  const ImportAccountsPage({super.key});

  @override
  ConsumerState<ImportAccountsPage> createState() => _ImportAccountsPageState();
}

class _ImportAccountsPageState extends ConsumerState<ImportAccountsPage> {
  final List<_ImportDraft> drafts = [];
  bool importing = false;

  @override
  void initState() {
    super.initState();

    final importable = ref.read(connectBankFlowProvider).importable;
    for (final account in importable) {
      drafts.add(
        _ImportDraft(
          account: account,
          nameController: TextEditingController(
            text: account.name ?? account.product ?? "Account",
          ),
        ),
      );
    }
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
    if (selected.isEmpty) return;

    setState(() => importing = true);
    try {
      final syncedCount = await ref
          .read(connectBankFlowProvider.notifier)
          .importAccounts([
            for (final draft in selected)
              BankAccountImportSelection(
                account: draft.account,
                name: draft.nameController.text.trim().isEmpty
                    ? "Account"
                    : draft.nameController.text.trim(),
                symbol: draft.symbol,
                color: draft.color,
                // Waits for the balance fetch instead of reading whatever
                // value happened to be cached so far: a balance that hasn't
                // resolved yet must never silently import as a 0 starting
                // value.
                startingValue:
                    await ref.read(
                      ebAccountBalanceProvider(draft.account.uid).future,
                    ) ??
                    0,
              ),
          ]);
      if (!mounted) return;

      // The snack bar goes through the root messenger: this route is about
      // to be popped, so its own context cannot show anything.
      Navigator.popUntil(context, ModalRoute.withName('/connect-bank'));
      showRootSnackBar(
        message:
            "${selected.length} accounts imported, "
            "$syncedCount transactions synced",
      );
    } on ConnectBankFlowException catch (e) {
      if (!mounted) return;
      showErrorDialog(context, e.message);
    } catch (e) {
      if (!mounted) return;
      showErrorDialog(context, 'Could not import the accounts');
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(connectBankFlowProvider).session;
    final selectedCount = drafts.where((draft) => draft.selected).length;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
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
              onPressed: selectedCount == 0 || importing ? null : _import,
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
                    "${session?.aspspName ?? 'Bank'} · "
                    "${drafts.length} accounts",
                    style: Theme.of(context).textTheme.bodySmall!.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            if (drafts.isEmpty)
              Padding(
                padding: const EdgeInsets.all(Sizes.xl),
                child: Text(
                  "This bank returned no account",
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            for (final draft in drafts)
              AccountImportTile(
                account: draft.account,
                selected: draft.selected,
                nameController: draft.nameController,
                symbol: draft.symbol,
                color: draft.color,
                onSelectedChanged: (value) =>
                    setState(() => draft.selected = value),
                onIconChanged: (icon) => setState(() => draft.symbol = icon),
                onColorChanged: (color) => setState(() => draft.color = color),
              ),
          ],
        ),
      ),
    );
  }
}
