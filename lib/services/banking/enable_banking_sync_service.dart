import 'dart:developer' as developer;

import '../../model/bank_account.dart';
import '../../model/bank_connection.dart';
import '../../model/transaction.dart';
import '../database/repositories/account_repository.dart';
import '../database/repositories/bank_connection_repository.dart';
import '../database/repositories/transactions_repository.dart';
import 'enable_banking_api.dart';
import 'enable_banking_exception.dart';
import 'enable_banking_transaction_mapper.dart';
import 'models/eb_balance.dart';
import 'models/eb_transaction.dart';

// Appends an occurrence index to fallback dedup keys (used when the ASPSP
// sends no entry_reference/transaction_id) so two same-day transactions
// with identical amount/description don't collide and get dropped by
// insertMissing.
List<Transaction> _disambiguateFallbackIds(
  List<EbTransaction> source,
  List<Transaction> mapped,
) {
  final occurrences = <String, int>{};
  final result = <Transaction>[];
  for (var i = 0; i < mapped.length; i++) {
    final key = mapped[i].externalId;
    final isFallbackKey =
        source[i].entryReference == null &&
        source[i].transactionId == null &&
        key != null;
    if (!isFallbackKey) {
      result.add(mapped[i]);
      continue;
    }

    final occurrence = occurrences[key] ?? 0;
    occurrences[key] = occurrence + 1;
    result.add(mapped[i].copy(externalId: '$key#$occurrence'));
  }
  return result;
}

// Re-fetched every sync so a transaction still pending on the previous run
// is picked up once it books with the same entry_reference.
const _kSyncMargin = Duration(days: 3);

const _kInitialSyncWindow = Duration(days: 90);

class EnableBankingSyncService {
  EnableBankingSyncService({
    required EnableBankingApi api,
    required AccountRepository accountRepository,
    required TransactionsRepository transactionsRepository,
    required BankConnectionRepository bankConnectionRepository,
  }) : _api = api,
       _accountRepository = accountRepository,
       _transactionsRepository = transactionsRepository,
       _bankConnectionRepository = bankConnectionRepository;

  final EnableBankingApi _api;
  final AccountRepository _accountRepository;
  final TransactionsRepository _transactionsRepository;
  final BankConnectionRepository _bankConnectionRepository;

  Future<int> syncAccount(BankAccount account) async {
    final accountUid = account.ebAccountUid;
    if (accountUid == null) return 0;

    final now = DateTime.now();
    final dateFrom = account.lastSyncAt != null
        ? account.lastSyncAt!.subtract(_kSyncMargin)
        : now.subtract(_kInitialSyncWindow);

    final booked = <EbTransaction>[];
    String? continuationKey;
    do {
      final page = await _api.getTransactions(
        accountUid,
        dateFrom: dateFrom,
        continuationKey: continuationKey,
      );
      booked.addAll(page.transactions.where((tx) => tx.isBooked));
      continuationKey = page.continuationKey;
    } while (continuationKey != null && continuationKey.isNotEmpty);

    final mapped = booked
        .map((tx) => mapEbTransaction(tx, idBankAccount: account.id!))
        .toList();
    final disambiguated = _disambiguateFallbackIds(booked, mapped);
    final insertedCount = await _transactionsRepository.insertMissing(
      disambiguated,
    );

    final currentBalance = preferredEbBalanceAmount(
      await _api.getBalances(accountUid),
    );
    if (currentBalance != null) {
      await _accountRepository.reconcileLinkedBalance(
        account.id!,
        currentBalance,
      );
    }

    await _accountRepository.updateLastSync(account.id!, now);
    return insertedCount;
  }

  // On a 401 the connection is marked EXPIRED and its remaining accounts
  // are skipped; any other error is isolated to the account it happened on
  // so one flaky account doesn't stop the rest.
  Future<Map<int, int>> syncConnection(BankConnection connection) async {
    final linked = (await _accountRepository.selectLinked())
        .where((account) => account.ebConnectionId == connection.id)
        .toList();

    final synced = <int, int>{};
    for (final account in linked) {
      try {
        synced[account.id!] = await syncAccount(account);
      } on EnableBankingException catch (e) {
        if (!e.isUnauthorized) {
          _logSyncFailure(account, e);
          continue;
        }
        await _bankConnectionRepository.markStatus(
          connection.id!,
          BankConnectionStatus.expired,
        );
        break;
      } catch (e) {
        _logSyncFailure(account, e);
      }
    }
    return synced;
  }

  void _logSyncFailure(BankAccount account, Object error) {
    developer.log(
      'Sync failed for account ${account.id}: $error',
      name: 'EnableBankingSyncService',
    );
  }

  // Any exception is swallowed and logged, not just EnableBankingException,
  // so one broken connection doesn't block the others or fail silently.
  Future<void> syncAll() async {
    final connections = await _bankConnectionRepository.selectActive();
    for (final connection in connections) {
      try {
        await syncConnection(connection);
      } catch (e) {
        developer.log(
          'Sync failed for connection ${connection.id} '
          '(${connection.aspspName}/${connection.aspspCountry}): $e',
          name: 'EnableBankingSyncService',
        );
      }
    }
  }
}
