import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../constants/style.dart';
import '../../../model/category_transaction.dart';
import '../../../model/transaction.dart';
import '../../../providers/accounts_provider.dart';
import '../../../providers/categories_provider.dart';
import '../../../providers/recurring_transactions_provider.dart';
import '../../../providers/transactions_provider.dart';
import '../../../services/database/repositories/transactions_repository.dart';
import '../../../ui/device.dart';
import '../../../ui/extensions.dart';
import "widgets/account_selector.dart";
import 'widgets/amount_section.dart';
import "widgets/category_selector.dart";
import 'widgets/details_list_disabled_tile.dart';
import 'widgets/details_list_tile.dart';
import 'widgets/duplicate_transaction_dialog.dart';
import 'widgets/label_list_tile.dart';
import 'widgets/recurrence_list_tile.dart';

class CreateTransactionPage extends ConsumerStatefulWidget {
  const CreateTransactionPage({super.key, this.transaction});

  final Transaction? transaction;

  @override
  ConsumerState<CreateTransactionPage> createState() =>
      _CreateTransactionPage();
}

class _CreateTransactionPage extends ConsumerState<CreateTransactionPage> {
  final TextEditingController amountController = TextEditingController();
  final TextEditingController noteController = TextEditingController();
  bool recurrencyEditingPermitted = true;
  bool _isSaveEnabled = false;
  bool _isSubmitting = false;
  bool _saveCompleted = false;
  String? _saveError;
  CategoryTransaction? _suggestedCategory;
  String? _suggestedLabel;

  @override
  void initState() {
    if (widget.transaction != null) {
      _isSaveEnabled = true;
      recurrencyEditingPermitted = !widget.transaction!.recurring;
      amountController.text = widget.transaction?.amount.toCurrency() ?? '';
      noteController.text = widget.transaction?.note ?? '';
    }
    amountController.addListener(_updateAmount);
    if (widget.transaction == null) {
      noteController.addListener(_suggestCategory);
    }

    super.initState();
  }

  @override
  void dispose() {
    amountController.dispose();
    noteController.dispose();
    super.dispose();
  }

  String getCleanAmountString() {
    // Remove all non-numeric characters
    var cleanNumberString = amountController.text.replaceAll(
      RegExp(r'[^0-9\.]'),
      '',
    );

    // Remove leading zeros only if the number does not start with "0."
    if (!cleanNumberString.startsWith('0.')) {
      cleanNumberString = cleanNumberString.replaceAll(
        RegExp(r'^0+(?!\.)'),
        '',
      );
    }

    if (cleanNumberString.startsWith('.')) {
      cleanNumberString = '0$cleanNumberString';
    }

    return cleanNumberString;
  }

  void _updateAmount() {
    final selectedType = ref.read(selectedTransactionTypeProvider);

    var toBeWritten = getCleanAmountString();

    if (selectedType == TransactionType.expense) {
      // apply the minus sign if it's an expense
      if (toBeWritten.isNotEmpty) {
        toBeWritten = "-$toBeWritten";
      }
    }

    if (toBeWritten != amountController.text) {
      // only update the controller if the value is different
      amountController.text = toBeWritten;
      amountController.selection = TextSelection.fromPosition(
        TextPosition(offset: toBeWritten.length),
      );
    }
    final selectedAccount = ref.read(selectedBankAccountProvider) != null;
    final selectedAccountTransfer =
        ref.read(bankAccountTransferProvider) != null;
    final selectedCategory = ref.read(selectedCategoryProvider) != null;
    // A reconciliation adjustment has no category and its picker is hidden, so it can't be required to enable saving.
    final isReconciliation = widget.transaction?.isReconciliation ?? false;
    setState(() {
      _isSaveEnabled = amountController.text.isNotEmpty && selectedAccount;
      switch (selectedType) {
        case TransactionType.expense:
        case TransactionType.income:
          _isSaveEnabled &= isReconciliation || selectedCategory;
          break;
        case TransactionType.transfer:
          _isSaveEnabled &= selectedAccountTransfer;
          break;
      }
    });
  }

  // Pre-select the category last used for a transaction with the same label,
  // unless the user has already picked one manually
  void _suggestCategory() async {
    final label = noteController.text.trim();
    final selectedType = ref.read(selectedTransactionTypeProvider);
    final selectedCategory = ref.read(selectedCategoryProvider);
    if (label == _suggestedLabel ||
        selectedType == TransactionType.transfer ||
        (selectedCategory != null && selectedCategory != _suggestedCategory)) {
      return;
    }
    _suggestedLabel = label;

    final category = label.isEmpty
        ? null
        : await ref
              .read(transactionsRepositoryProvider)
              .getLastCategoryByLabel(label, selectedType);
    if (!mounted ||
        noteController.text.trim() != label ||
        ref.read(selectedTransactionTypeProvider) != selectedType) {
      return;
    }

    _suggestedCategory = category;
    ref.read(selectedCategoryProvider.notifier).setCategory(category);
  }

  Future<void> _refreshAccountAndNavigateBack() async {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    final account = ref.read(selectedBankAccountProvider);
    var refreshFailed = false;
    try {
      if (account != null) {
        await ref.read(accountsProvider.notifier).refreshAccount(account);
      }
    } catch (_) {
      refreshFailed = true;
    }
    if (!mounted || (route != null && !route.isCurrent)) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    if (refreshFailed) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text(
            'Transaction saved. Some totals could not be refreshed.',
          ),
        ),
      );
    }
  }

  Future<void> _createOrUpdateTransaction() async {
    if (_isSubmitting) return;
    if (_saveCompleted) {
      await _refreshAccountAndNavigateBack();
      return;
    }
    final cleanAmount = getCleanAmountString();
    if (cleanAmount.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _isSubmitting = true;
      _saveError = null;
    });
    var saved = false;
    try {
      final type = ref.read(selectedTransactionTypeProvider);
      final recurring =
          type != TransactionType.transfer &&
          ref.read(selectedRecurringPayProvider);
      final original = widget.transaction;
      if (original != null) {
        if (recurring && !original.recurring) {
          saved =
              await ref
                  .read(recurringTransactionsProvider.notifier)
                  .create(
                    cleanAmount.toNum(),
                    noteController.text,
                    type,
                    existingTransaction: original,
                  ) !=
              null;
        } else {
          saved = await ref
              .read(transactionsProvider.notifier)
              .updateWithResult(
                original,
                cleanAmount.toNum(),
                noteController.text,
                recurringTransactionId: original.idRecurringTransaction,
              );
        }
      } else if (recurring && type != TransactionType.transfer) {
        saved =
            await ref
                .read(recurringTransactionsProvider.notifier)
                .create(cleanAmount.toNum(), noteController.text, type) !=
            null;
      } else {
        saved = await ref
            .read(transactionsProvider.notifier)
            .createWithResult(cleanAmount.toNum(), noteController.text);
      }
      if (saved) {
        _saveCompleted = true;
        await _refreshAccountAndNavigateBack();
      }
    } catch (_) {
      // A failed write must leave the user's form and draft available for retry.
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          if (!saved) {
            _saveError =
                'Could not save transaction. Your changes are still here. Try again.';
          }
        });
      }
    }
  }

  void _deleteTransaction() async {
    await ref
        .read(transactionsProvider.notifier)
        .delete(widget.transaction!.id!)
        .whenComplete(() => _refreshAccountAndNavigateBack());
  }

  @override
  Widget build(BuildContext context) {
    final selectedType = ref.watch(selectedTransactionTypeProvider);
    // A category belongs to a single transaction type, so drop it when the
    // type changes and look for a suggestion matching the new type
    ref.listen(selectedTransactionTypeProvider, (previous, next) {
      final category = ref.read(selectedCategoryProvider);
      if (category != null && !category.type.supports(next)) {
        ref.read(selectedCategoryProvider.notifier).setCategory(null);
      }
      if (widget.transaction == null) {
        _suggestedLabel = null;
        _suggestCategory();
      }
    });

    // A reconciliation adjustment (AccountsProvider._reconcileAccount) has no category, is never recurring, and its amount/type/date are fixed by the balance difference at the moment it was created. A bank-imported transaction (Enable Banking) has its account, date and income/expense type fixed by the bank's own record, and can't be made recurring either.
    final isReconciliation = widget.transaction?.isReconciliation ?? false;
    final isBankImported = widget.transaction?.isBankImported ?? false;
    final canEditCategory = !isReconciliation;
    final canEditAccount = !isReconciliation && !isBankImported;
    final canEditDateAndType = !isReconciliation && !isBankImported;
    final canEditRecurring = !isReconciliation && !isBankImported;
    final canEditAmount = !isReconciliation && !isBankImported;

    _updateAmount();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          (widget.transaction != null)
              ? "Editing transaction"
              : "New transaction",
        ),
        actions: [
          // A bank-imported transaction is the bank's own record: duplicating it would create an untracked manual copy, and deleting it would just reappear on the next sync (insertMissing dedups on externalId, it doesn't know about local deletions) — hide both actions instead of offering something that can't work as expected.
          if (widget.transaction != null && !isBankImported) ...[
            IconButton(
              icon: Icon(
                Icons.copy,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              onPressed: _isSubmitting || _saveCompleted
                  ? null
                  : () => showDialog(
                      context: context,
                      builder: (_) => DuplicateTransactionDialog(
                        transaction: widget.transaction!,
                      ),
                    ),
            ),
            IconButton(
              icon: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              onPressed: _isSubmitting || _saveCompleted
                  ? null
                  : _deleteTransaction,
            ),
          ],
        ],
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_saveError != null)
                  Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: Sizes.sm),
                      child: Text(
                        _saveError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                if (_isSubmitting)
                  Semantics(
                    label: 'Saving transaction',
                    child: const LinearProgressIndicator(),
                  ),
                ElevatedButton(
                  onPressed:
                      !_isSubmitting && (_isSaveEnabled || _saveCompleted)
                      ? _createOrUpdateTransaction
                      : null,
                  child: Text(
                    _saveCompleted
                        ? 'DONE'
                        : widget.transaction != null
                        ? 'UPDATE TRANSACTION'
                        : 'ADD TRANSACTION',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      body: AbsorbPointer(
        absorbing: _isSubmitting || _saveCompleted,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: Sizes.md * 6),
          child: Column(
            children: [
              AmountSection(
                amountController,
                typeEditingPermitted: canEditDateAndType,
                amountEditingPermitted: canEditAmount,
              ),
              Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(
                  left: Sizes.lg,
                  top: Sizes.xxl,
                  bottom: Sizes.sm,
                ),
                child: Text(
                  "DETAILS",
                  style: Theme.of(context).textTheme.labelLarge!.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              Container(
                color: Theme.of(context).colorScheme.surface,
                child: Column(
                  children: [
                    LabelListTile(noteController),
                    const Divider(),
                    if (selectedType != TransactionType.transfer) ...[
                      if (canEditAccount)
                        DetailsListTile(
                          title: "Account",
                          icon: Icons.account_balance_wallet,
                          value: ref.watch(selectedBankAccountProvider)?.name,
                          callback: () {
                            FocusManager.instance.primaryFocus?.unfocus();
                            showModalBottomSheet(
                              context: context,
                              clipBehavior: Clip.antiAliasWithSaveLayer,
                              isScrollControlled: true,
                              useSafeArea: true,
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.only(
                                  topLeft: Radius.circular(Sizes.borderRadius),
                                  topRight: Radius.circular(Sizes.borderRadius),
                                ),
                              ),
                              builder: (_) => DraggableScrollableSheet(
                                expand: false,
                                minChildSize: 0.5,
                                initialChildSize: 0.7,
                                maxChildSize: 0.9,
                                builder: (_, controller) => AccountSelector(
                                  scrollController: controller,
                                ),
                              ),
                            );
                          },
                        )
                      else
                        NonEditableDetailsListTile(
                          title: "Account",
                          icon: Icons.account_balance_wallet,
                          value: ref.watch(selectedBankAccountProvider)?.name,
                        ),
                      const Divider(),
                      if (canEditCategory) ...[
                        DetailsListTile(
                          title: "Category",
                          icon: Icons.list_alt,
                          value: ref.watch(selectedCategoryProvider)?.name,
                          callback: () {
                            FocusManager.instance.primaryFocus?.unfocus();
                            showModalBottomSheet(
                              context: context,
                              clipBehavior: Clip.antiAliasWithSaveLayer,
                              isScrollControlled: true,
                              useSafeArea: true,
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.only(
                                  topLeft: Radius.circular(Sizes.borderRadius),
                                  topRight: Radius.circular(Sizes.borderRadius),
                                ),
                              ),
                              builder: (_) => DraggableScrollableSheet(
                                expand: false,
                                minChildSize: 0.5,
                                initialChildSize: 0.7,
                                maxChildSize: 0.9,
                                builder: (_, controller) => CategorySelector(
                                  scrollController: controller,
                                ),
                              ),
                            );
                          },
                        ),
                        const Divider(),
                      ],
                    ],
                    if (canEditDateAndType)
                      DetailsListTile(
                        title: "Date",
                        icon: Icons.calendar_month,
                        value: ref.watch(selectedDateProvider).formatEDMY(),
                        callback: () async {
                          FocusManager.instance.primaryFocus?.unfocus();
                          if (Platform.isIOS) {
                            showCupertinoModalPopup(
                              context: context,
                              builder: (_) => Container(
                                height: 300,
                                color: CupertinoDynamicColor.resolve(
                                  CupertinoColors.secondarySystemBackground,
                                  context,
                                ),
                                child: CupertinoDatePicker(
                                  initialDateTime: ref.watch(
                                    selectedDateProvider,
                                  ),
                                  minimumYear: 2015,
                                  maximumYear: 2050,
                                  mode: CupertinoDatePickerMode.date,
                                  onDateTimeChanged: (date) => ref
                                      .read(selectedDateProvider.notifier)
                                      .setDate(date),
                                ),
                              ),
                            );
                          } else if (Platform.isAndroid) {
                            final DateTime? pickedDate = await showDatePicker(
                              context: context,
                              initialDate: ref.watch(selectedDateProvider),
                              firstDate: DateTime(2015),
                              lastDate: DateTime(2050),
                            );
                            if (pickedDate != null) {
                              ref
                                  .read(selectedDateProvider.notifier)
                                  .setDate(pickedDate);
                            }
                          }
                        },
                      )
                    else
                      NonEditableDetailsListTile(
                        title: "Date",
                        icon: Icons.calendar_month,
                        value: ref.watch(selectedDateProvider).formatEDMY(),
                      ),
                    if (canEditRecurring)
                      RecurrenceListTile(
                        recurrencyEditingPermitted: recurrencyEditingPermitted,
                        selectedTransaction: widget.transaction,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
