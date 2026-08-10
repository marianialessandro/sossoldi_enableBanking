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
import 'models/eb_transaction.dart';

/// Disambiguates [mapped] transactions that share a fallback dedup key —
/// the composite of date/amount/direction/description that
/// [EbTransaction.stableId] falls back to only when the ASPSP sends
/// neither `entry_reference` nor `transaction_id` — by appending their
/// occurrence index within this batch. Two genuinely distinct same-day
/// purchases with identical amount/description (e.g. two coffees at the
/// same shop) then become `<key>#0`/`<key>#1` instead of colliding on the
/// same id and having the second silently dropped by
/// `TransactionsRepository.insertMissing`.
///
/// Best effort, not a guarantee: it only holds as long as the bank returns
/// the same transactions in the same relative order on every sync, which
/// isn't documented by the API but is what ASPSPs do in practice for a
/// stable historical date range. Transactions with a bank-provided id are
/// left untouched — changing their externalId format would break dedup
/// against everything already synced under the un-suffixed id.
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

/// Re-fetched on every sync so a transaction still `PDNG` (pending) on the
/// previous run is picked up once it books with the same `entry_reference`.
const _kSyncMargin = Duration(days: 3);

/// Window fetched on an account's very first sync (no `lastSyncAt` yet).
const _kInitialSyncWindow = Duration(days: 90);

/// Fetches, maps and dedups Enable Banking transactions into the local
/// database, one linked [BankAccount]/[BankConnection] at a time.
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

  /// Fetches and inserts new booked transactions for [account] and updates
  /// its `lastSyncAt`. Returns the number of transactions actually inserted
  /// (0 for an account not linked to Enable Banking).
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

    await _accountRepository.updateLastSync(account.id!, now);
    return insertedCount;
  }

  /// Syncs every account imported from [connection]. On a 401 (expired or
  /// revoked consent) the connection is marked `EXPIRED` and its remaining
  /// accounts are skipped for this run, since they all share the same
  /// expired consent; other connections are unaffected (see [syncAll]). Any
  /// other error (timeout, malformed response, ...) is isolated to the
  /// account it happened on — logged and skipped — so a single flaky
  /// account doesn't stop the rest of the connection's accounts from
  /// syncing.
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

  /// Syncs every `ACTIVE` connection. A connection whose sync fails outright
  /// (e.g. a network error, a malformed response from the bank, or an
  /// expired consent already handled by [syncConnection]) does not block
  /// the others: any exception is swallowed, not just [EnableBankingException].
  /// Logged rather than dropped silently — otherwise a connection broken in
  /// a way that never leaves this method (e.g. a persistently malformed
  /// response) fails every scheduled sync forever with no diagnosable trace.
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
        // Skip this connection for now; the next scheduled sync retries it.
      }
    }
  }
}
