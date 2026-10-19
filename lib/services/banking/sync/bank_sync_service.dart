import 'dart:async';
import 'dart:math';
import 'dart:convert';
import '../banking_balance.dart';

import 'package:sqflite/sqflite.dart';

import '../../../model/bank_connection.dart';
import '../../database/repositories/bank_sync_repository.dart';
import 'bank_balance_selector.dart';
import '../bank_account_data_source.dart';
import '../bank_consent_service.dart';
import '../banking_connection.dart';
import '../bank_institution_directory.dart';
import '../bank_institution.dart';
import '../bank_authorization_context.dart';
import '../banking_reference.dart';
import '../banking_request_context.dart';
import '../banking_exception.dart';
import 'bank_money.dart';
import 'bank_remote_transaction.dart';
import 'bank_sync_request.dart';
import 'bank_sync_result.dart';
import '../banking_transaction.dart';

class BankSyncLimits {
  final int pages;
  final int records;
  final int retries;
  final Duration timeout;
  final Duration manualInterval;
  final Duration backgroundInterval;

  const BankSyncLimits({
    this.pages = 100,
    this.records = 50000,
    this.retries = 3,
    this.timeout = const Duration(minutes: 3),
    this.manualInterval = const Duration(seconds: 15),
    this.backgroundInterval = const Duration(hours: 6),
  });
}

/// One attempt owns this monotonic deadline, including every retry and resampling round.
class BankSyncDeadline {
  final Duration timeout;
  final Stopwatch _watch = Stopwatch()..start();
  BankSyncDeadline(this.timeout);
  Duration get elapsed => _watch.elapsed;
  Future<T> run<T>(Future<T> Function() action) {
    final remaining = timeout - elapsed;
    if (remaining <= Duration.zero) throw TimeoutException('Sync deadline');
    return action().timeout(remaining);
  }

  void stop() => _watch.stop();
}

/// Fetches and validates a complete batch before a single local commit.
class BankSyncService {
  final BankAccountDataSource _accountData;
  final BankConsentService? _consent;
  final BankInstitutionDirectory _institutions;
  final String _providerId;
  final BankSyncRepository _repository;
  final BankAuthorizationContextReader _readContext;
  final BankSyncLimits limits;
  final Future<void> Function(Duration) _sleep;
  final double Function() _jitter;
  final DateTime Function() _clock;
  final Duration Function()? _elapsedOverride;
  final BankSyncDeadline Function(Duration) _deadline;
  final Stopwatch _monotonic = Stopwatch()..start();
  final Map<int, Future<BankSyncResult>> _running = {};
  final Map<(int, BankSyncTrigger), Duration> _lastAttempt = {};

  BankSyncService({
    required BankAccountDataSource accountData,
    BankConsentService? consent,
    required BankInstitutionDirectory institutions,
    required String providerId,
    required BankSyncRepository repository,
    required BankAuthorizationContextReader readContext,
    this.limits = const BankSyncLimits(),
    Future<void> Function(Duration)? sleep,
    double Function()? jitter,
    DateTime Function()? clock,
    Duration Function()? elapsed,
    BankSyncDeadline Function(Duration)? deadline,
  }) : _accountData = accountData,
       _consent = consent,
       _institutions = institutions,
       _providerId = providerId,
       _repository = repository,
       _readContext = readContext,
       _sleep = sleep ?? Future<void>.delayed,
       _jitter = jitter ?? Random().nextDouble,
       _clock = clock ?? DateTime.now,
       _elapsedOverride = elapsed,
       _deadline = deadline ?? BankSyncDeadline.new {
    if (limits.pages < 1 ||
        limits.records < 1 ||
        limits.retries < 0 ||
        limits.retries > 10 ||
        limits.timeout <= Duration.zero) {
      throw ArgumentError('Invalid bank sync limits');
    }
  }

  Future<BankSyncResult> syncAccount(
    int accountId, {
    BankSyncRequest request = const BankSyncRequest(),
  }) {
    final running = _running[accountId];
    if (running != null) return running;
    final future = _sync(accountId, request);
    _running[accountId] = future;
    unawaited(
      future.then<void>(
        (_) {
          _running.remove(accountId);
        },
        onError: (Object error, StackTrace stack) {
          _running.remove(accountId);
        },
      ),
    );
    return future;
  }

  Future<BankSyncSummary> syncConnection(
    int connectionId, {
    BankSyncRequest request = const BankSyncRequest(),
  }) async {
    final results = <BankSyncResult>[];
    for (final id in await _repository.accountIds(
      connectionId: connectionId,
      providerId: _providerId,
    )) {
      results.add(await syncAccount(id, request: request));
    }
    return BankSyncSummary(results);
  }

  Future<BankSyncSummary> syncAll({
    BankSyncRequest request = const BankSyncRequest(),
  }) async {
    final results = <BankSyncResult>[];
    for (final id in await _repository.accountIds(providerId: _providerId)) {
      results.add(await syncAccount(id, request: request));
    }
    return BankSyncSummary(results);
  }

  Future<T> _retry<T>(
    Future<T> Function() action,
    BankSyncDeadline watch,
  ) async {
    for (var attempt = 0; ; attempt++) {
      final remaining = limits.timeout - watch.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('Sync deadline');
      try {
        return await watch.run(action);
      } on BankingException catch (error) {
        if (!error.isRetryable || attempt >= limits.retries) rethrow;
        final backoff = Duration(
          milliseconds: (500 * (1 << attempt) * (1 + _jitter())).round(),
        );
        final delay = error.retryAfter != null && error.retryAfter! > backoff
            ? error.retryAfter!
            : backoff;
        if (delay >= limits.timeout - watch.elapsed) rethrow;
        await _sleep(delay);
      }
    }
  }

  Future<BankSyncResult> _failure(
    int id,
    BankSyncStatus status,
    String warning, {
    int rejected = 0,
    required BankSyncContext? expected,
    BankConnectionStatus? markedStatus,
  }) async {
    final result = BankSyncResult(
      accountId: id,
      status: status,
      rejected: rejected,
      warnings: [warning],
    );
    try {
      await _repository.recordFailure(
        result,
        expected: expected,
        markedStatus: markedStatus,
      );
    } on DatabaseException {
      return BankSyncResult(
        accountId: id,
        status: BankSyncStatus.terminalFailure,
        rejected: rejected,
        warnings: [warning, 'audit_write_failed'],
      );
    }
    return result;
  }

  Future<BankSyncResult> _sync(int accountId, BankSyncRequest request) async {
    final watch = _deadline(limits.timeout);
    BankSyncContext? startedContext;
    BankConnectionStatus? markedStatus;
    Future<BankSyncResult> failure(
      int id,
      BankSyncStatus status,
      String warning, {
      int rejected = 0,
    }) => _failure(
      id,
      status,
      warning,
      rejected: rejected,
      expected: startedContext,
      markedStatus: markedStatus,
    );
    try {
      final context = await _repository.readContext(accountId);
      startedContext = context;
      final authorization = await _readContext();
      if (context.connection.providerId != _providerId ||
          authorization.providerId != _providerId ||
          context.connection.status != BankConnectionStatus.active ||
          context.connection.remoteConnectionId == null ||
          context.account.ebAccountUid == null ||
          authorization.applicationId != context.connection.applicationId) {
        return failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'consent_or_credentials_unavailable',
        );
      }
      final scale = BankMoney.scales[context.currency];
      if (scale == null || scale > 2) {
        return failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'unsupported_global_currency_precision',
        );
      }
      final interval = request.trigger == BankSyncTrigger.manual
          ? limits.manualInterval
          : limits.backgroundInterval;
      final key = (accountId, request.trigger);
      final last = _lastAttempt[key];
      final elapsed = _elapsedOverride?.call() ?? _monotonic.elapsed;
      if (last != null && elapsed - last < interval) {
        return BankSyncResult(
          accountId: accountId,
          status: BankSyncStatus.skipped,
          warnings: const ['throttled'],
        );
      }
      final completedAt = context.completedAt;
      final now = _clock().toUtc();
      if (request.trigger == BankSyncTrigger.background &&
          completedAt != null &&
          !completedAt.isAfter(now) &&
          now.difference(completedAt) < interval) {
        return BankSyncResult(
          accountId: accountId,
          status: BankSyncStatus.skipped,
          warnings: const ['not_due'],
        );
      }
      _lastAttempt[key] = elapsed;
      final banks = await _retry(
        () => _institutions.getInstitutions(
          country: context.connection.institutionCountry,
          customerType: context.connection.psuType == 'business'
              ? BankingCustomerType.business
              : BankingCustomerType.personal,
        ),
        watch,
      );
      final matches = banks
          .where(
            (bank) =>
                bank.providerId == _providerId &&
                bank.name == context.connection.institutionName &&
                bank.country == context.connection.institutionCountry,
          )
          .toList();
      if (matches.length != 1) {
        return failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'bank_metadata_unavailable',
        );
      }
      final requiredHeaders = matches.single.requiredPsuHeaders;
      Map<String, String> psuHeaders;
      try {
        psuHeaders = request.headersFor(requiredHeaders);
      } on FormatException {
        return failure(
          accountId,
          BankSyncStatus.partial,
          'manual_context_required',
        );
      }
      final headers = BankingRequestContext(psuHeaders: psuHeaders);
      final reference = BankingAccountReference(
        providerId: _providerId,
        remoteId: context.account.ebAccountUid!,
      );
      final details = await _retry(
        () => _accountData.getAccount(reference, context: headers),
        watch,
      );
      if (details.reference != reference) {
        return failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'account_identity_mismatch',
        );
      }
      if (details.currency != context.currency) {
        return failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'account_currency_mismatch',
        );
      }
      if (details.reference.identityKeys.isNotEmpty &&
          !details.reference.identityKeys.contains(
            context.account.identificationHash,
          )) {
        return failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'account_identity_mismatch',
        );
      }
      final warnings = <String>[];
      var strategy = BankingHistoryStrategy.longest;
      DateTime? dateFrom;
      if (context.checkpoint != null && context.checkpoint!.isAfter(now)) {
        dateFrom = null;
        strategy = BankingHistoryStrategy.longest;
        warnings.add('future_checkpoint_reset');
      }
      final budget = _SyncBudget(strategy, dateFrom);
      _SyncCohort? previous;
      late _SyncCohort accepted;
      BankBalanceSnapshot? balance;
      for (var round = 0; ; round++) {
        final cohort = await _collect(
          reference,
          headers,
          context.currency,
          budget,
          watch,
          warnings,
        );
        final same =
            previous != null && previous.fingerprint == cohort.fingerprint;
        if (same || (previous == null && !cohort.needsCoherence)) {
          accepted = cohort;
          balance = selectBankBalance(
            cohort.balances,
            cohort.items,
            context.currency,
            cohort.serverTime,
            coherentRead: same,
          );
          break;
        }
        if (round >= limits.retries) {
          return failure(
            accountId,
            BankSyncStatus.retryableFailure,
            'balance_snapshot_unstable',
          );
        }
        previous = cohort;
      }
      final items = accepted.items;
      final serverTime = accepted.serverTime;
      strategy = budget.strategy;
      dateFrom = budget.dateFrom;
      if (context.checkpoint != null &&
          items.isNotEmpty &&
          !items.any((item) => !item.date.isAfter(context.checkpoint!))) {
        warnings.add('history_overlap_missing');
      }
      if (!items.any((item) => item.status == 'BOOK') && balance != null) {
        warnings.add('empty_account_history_unverified');
      }
      if (balance == null) {
        warnings.add('no_comparable_booked_balance');
        if (!context.initialized) {
          return failure(
            accountId,
            BankSyncStatus.partial,
            'initial_balance_unverified',
          );
        }
      }
      if (context.connection.validUntil == null ||
          !context.connection.validUntil!.isAfter(serverTime)) {
        if (await _repository.markConsentFailure(
          context,
          BankConnectionStatus.expired,
        )) {
          markedStatus = BankConnectionStatus.expired;
        }
        return failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'consent_expired',
        );
      }
      if (watch.elapsed >= limits.timeout) {
        throw TimeoutException('Sync deadline');
      }
      final latestAuthorization = await _readContext();
      if (latestAuthorization.providerId != authorization.providerId ||
          latestAuthorization.applicationId != authorization.applicationId) {
        return failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'credentials_changed',
        );
      }
      if (watch.elapsed >= limits.timeout) {
        throw TimeoutException('Sync deadline');
      }
      return await _repository.commit(
        context,
        items,
        serverTime: serverTime,
        strategy: strategy == BankingHistoryStrategy.longest
            ? 'longest'
            : 'default',
        requestedFrom: dateFrom,
        requiredPsuHeaders: requiredHeaders,
        balance: balance,
        warnings: warnings,
      );
    } on _CollectionFailure catch (error) {
      return failure(
        accountId,
        error.partial
            ? BankSyncStatus.partial
            : BankSyncStatus.retryableFailure,
        error.code,
        rejected: error.rejected,
      );
    } on BankSyncIntegrityException catch (error) {
      return failure(accountId, BankSyncStatus.partial, error.code);
    } on BankingException catch (error) {
      if (startedContext != null) {
        var status = switch (error.failure) {
          BankingFailure.connectionExpired => BankConnectionStatus.expired,
          BankingFailure.connectionRevoked || BankingFailure.connectionClosed =>
            BankConnectionStatus.reauthRequired,
          _ => null,
        };
        if (error.failure == BankingFailure.notFound) {
          status = await _confirmedConsentFailure(startedContext);
        }
        if (status != null) {
          if (await _repository.markConsentFailure(startedContext, status)) {
            markedStatus = status;
          }
        }
      }
      return failure(
        accountId,
        error.isRetryable
            ? BankSyncStatus.retryableFailure
            : BankSyncStatus.terminalFailure,
        error.failure == BankingFailure.notFound
            ? 'account_not_found'
            : 'api_${error.failure.name}',
      );
    } on TimeoutException {
      return failure(
        accountId,
        BankSyncStatus.retryableFailure,
        'operation_timeout',
      );
    } on FormatException {
      return failure(
        accountId,
        BankSyncStatus.partial,
        'invalid_or_changed_sync_context',
      );
    } on TypeError {
      return failure(
        accountId,
        BankSyncStatus.partial,
        'invalid_response_schema',
      );
    } on DatabaseException {
      return failure(
        accountId,
        BankSyncStatus.retryableFailure,
        'database_commit_failed',
      );
    } finally {
      watch.stop();
    }
  }

  Future<_SyncCohort> _collect(
    BankingAccountReference reference,
    BankingRequestContext headers,
    String currency,
    _SyncBudget budget,
    BankSyncDeadline watch,
    List<String> warnings,
  ) async {
    final items = <BankRemoteTransaction>[];
    final records = <String>[];
    final cursors = <String>{};
    String? cursor;
    DateTime? pageTime;
    DateTime? earliestPage;
    var rejected = 0;
    do {
      if (budget.pages >= limits.pages) {
        throw const _CollectionFailure('page_limit');
      }
      budget.pages++;
      BankingTransactionsPage page;
      try {
        page = await _retry(
          () => _accountData.getTransactions(
            reference,
            query: BankingTransactionQuery(
              dateFrom: budget.dateFrom,
              cursor: cursor,
              strategy: budget.strategy,
              context: headers,
              collectRejectedRecords: true,
            ),
          ),
          watch,
        );
      } on BankingException catch (error) {
        if (cursor != null ||
            budget.fallback ||
            error.failure != BankingFailure.unsupportedHistoryPeriod) {
          rethrow;
        }
        budget.fallback = true;
        budget.strategy = BankingHistoryStrategy.standard;
        budget.dateFrom = null;
        warnings.add('bank_default_history_fallback');
        if (budget.pages >= limits.pages) {
          throw const _CollectionFailure('page_limit');
        }
        budget.pages++;
        page = await _retry(
          () => _accountData.getTransactions(
            reference,
            query: BankingTransactionQuery(
              strategy: budget.strategy,
              context: headers,
              collectRejectedRecords: true,
            ),
          ),
          watch,
        );
      }
      final time = page.serverTime?.toUtc();
      if (time != null) {
        budget.observe(time, limits.timeout);
        if (pageTime == null || time.isAfter(pageTime)) pageTime = time;
        if (earliestPage == null || time.isBefore(earliestPage)) {
          earliestPage = time;
        }
      }
      budget.records += page.transactions.length + page.rejectedRecords;
      if (budget.records > limits.records) {
        throw const _CollectionFailure('record_limit');
      }
      rejected += page.rejectedRecords;
      for (final transaction in page.transactions) {
        try {
          final item = BankRemoteTransaction.fromTransaction(
            transaction,
            currency,
          );
          items.add(item);
          records.add(
            jsonEncode([
              item.key,
              item.entryReference,
              item.transactionId,
              item.status,
              item.money.currency,
              item.money.minorUnits.toString(),
              item.date.toIso8601String(),
              item.note,
              transaction.bookingDate?.toIso8601String(),
              transaction.valueDate?.toIso8601String(),
              transaction.transactionDate?.toIso8601String(),
              transaction.note,
              transaction.creditorName,
              transaction.debtorName,
              transaction.remittanceInformation,
            ]),
          );
        } on FormatException {
          rejected++;
        }
      }
      cursor = page.nextCursor;
      if (cursor != null && !cursors.add(cursor)) {
        throw const _CollectionFailure('continuation_cycle');
      }
    } while (cursor != null);
    if (pageTime == null) {
      throw const _CollectionFailure('missing_server_clock');
    }
    final balances = await _retry(
      () => _accountData.getBalances(reference, context: headers),
      watch,
    );
    var bound = pageTime;
    var needsCoherence = false;
    for (final balance in balances) {
      final acquired = balance.acquiredAt?.toUtc();
      if (acquired != null) {
        budget.observe(acquired, limits.timeout);
        if (acquired.isAfter(bound)) bound = acquired;
      }
      if (balance.amount.currency != currency ||
          !const {
            BankingBalanceKind.closingBooked,
            BankingBalanceKind.interimBooked,
          }.contains(balance.kind)) {
        continue;
      }
      if (acquired != null && acquired.isAfter(earliestPage!) ||
          balance.observedAt != null &&
              balance.observedAt!.isAfter(earliestPage!)) {
        needsCoherence = true;
      }
      final ref = balance.referenceDate;
      if (ref != null &&
          acquired != null &&
          (ref.year != acquired.year ||
              ref.month != acquired.month ||
              ref.day != acquired.day)) {
        needsCoherence = true;
      }
    }
    final serverDay = DateTime.utc(bound.year, bound.month, bound.day);
    rejected += items
        .where((item) => item.status == 'BOOK' && item.date.isAfter(serverDay))
        .length;
    if (rejected > 0) {
      throw _CollectionFailure(
        'invalid_financial_records',
        rejected: rejected,
        partial: true,
      );
    }
    final unique = <String>{};
    if (items.any((item) => !unique.add(item.key))) {
      throw const _CollectionFailure(
        'ambiguous_transaction_identity',
        partial: true,
      );
    }
    return _SyncCohort(items, balances, bound, needsCoherence, records);
  }

  Future<BankConnectionStatus?> _confirmedConsentFailure(
    BankSyncContext context,
  ) async {
    final consent = _consent;
    if (consent == null) return null;
    try {
      final reference = BankingConnectionReference(
        providerId: context.connection.providerId,
        remoteId: context.connection.remoteConnectionId!,
      );
      final connection = await consent.getConnection(reference);
      if (connection.reference != reference) return null;
      return switch (connection.status) {
        BankingConnectionStatus.expired => BankConnectionStatus.expired,
        BankingConnectionStatus.cancelled ||
        BankingConnectionStatus.closed ||
        BankingConnectionStatus.invalid ||
        BankingConnectionStatus.revoked => BankConnectionStatus.reauthRequired,
        _ => null,
      };
    } on BankingException catch (error) {
      return switch (error.failure) {
        BankingFailure.connectionExpired => BankConnectionStatus.expired,
        BankingFailure.notFound ||
        BankingFailure.connectionRevoked ||
        BankingFailure.connectionClosed => BankConnectionStatus.reauthRequired,
        _ => null,
      };
    } catch (_) {
      // An inconclusive session check must not invalidate the other accounts.
      return null;
    }
  }
}

class _CollectionFailure implements Exception {
  final String code;
  final int rejected;
  final bool partial;
  const _CollectionFailure(
    this.code, {
    this.rejected = 0,
    this.partial = false,
  });
}

class _SyncBudget {
  int pages = 0;
  int records = 0;
  bool fallback = false;
  BankingHistoryStrategy strategy;
  DateTime? dateFrom;
  DateTime? earliest;
  DateTime? latest;
  _SyncBudget(this.strategy, this.dateFrom);
  void observe(DateTime time, Duration timeout) {
    if (earliest == null || time.isBefore(earliest!)) earliest = time;
    if (latest == null || time.isAfter(latest!)) latest = time;
    if (latest!.difference(earliest!) > timeout + const Duration(minutes: 1)) {
      throw const _CollectionFailure('server_clock_changed');
    }
  }
}

class _SyncCohort {
  final List<BankRemoteTransaction> items;
  final List<BankingBalance> balances;
  final DateTime serverTime;
  final bool needsCoherence;
  final List<String> records;
  _SyncCohort(
    this.items,
    this.balances,
    this.serverTime,
    this.needsCoherence,
    this.records,
  );
  String get fingerprint {
    final transactions = records.toList()..sort();
    final snapshots =
        balances
            .map(
              (item) => jsonEncode([
                item.kind.name,
                item.amount.currency,
                BankMoney.scales.containsKey(item.amount.currency)
                    ? BankMoney.parse(
                        item.amount.decimalAmount,
                        item.amount.currency,
                      ).minorUnits.toString()
                    : item.amount.decimalAmount,
                BankRemoteTransaction.normalizeId(item.lastCommittedEntryId),
                item.referenceDate?.toIso8601String(),
                item.observedAt?.toUtc().toIso8601String(),
              ]),
            )
            .toList()
          ..sort();
    return jsonEncode([transactions, snapshots]);
  }
}
