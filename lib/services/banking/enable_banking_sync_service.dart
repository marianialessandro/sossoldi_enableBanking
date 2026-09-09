import 'dart:async';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../../model/bank_connection.dart';
import '../database/repositories/bank_sync_repository.dart';
import 'bank_balance_selector.dart';
import 'enable_banking_api.dart';
import 'enable_banking_exception.dart';
import 'models/bank_money.dart';
import 'models/bank_remote_transaction.dart';
import 'models/bank_sync_request.dart';
import 'models/bank_sync_result.dart';
import 'models/eb_transactions_page.dart';

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

/// Fetches and validates a complete batch before a single local commit.
class EnableBankingSyncService {
  final EnableBankingApi _api;
  final BankSyncRepository _repository;
  final Future<String?> Function() _applicationId;
  final BankSyncLimits limits;
  final Future<void> Function(Duration) _sleep;
  final double Function() _jitter;
  final DateTime Function() _clock;
  final Duration Function()? _elapsedOverride;
  final Stopwatch _monotonic = Stopwatch()..start();
  final Map<int, Future<BankSyncResult>> _running = {};
  final Map<(int, BankSyncTrigger), Duration> _lastAttempt = {};

  EnableBankingSyncService({
    required EnableBankingApi api,
    required BankSyncRepository repository,
    required Future<String?> Function() applicationId,
    this.limits = const BankSyncLimits(),
    Future<void> Function(Duration)? sleep,
    double Function()? jitter,
    DateTime Function()? clock,
    Duration Function()? elapsed,
  }) : _api = api,
       _repository = repository,
       _applicationId = applicationId,
       _sleep = sleep ?? Future<void>.delayed,
       _jitter = jitter ?? Random().nextDouble,
       _clock = clock ?? DateTime.now,
       _elapsedOverride = elapsed {
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
    for (final id in await _repository.accountIds(connectionId: connectionId)) {
      results.add(await syncAccount(id, request: request));
    }
    return BankSyncSummary(results);
  }

  Future<BankSyncSummary> syncAll({
    BankSyncRequest request = const BankSyncRequest(),
  }) async {
    final results = <BankSyncResult>[];
    for (final id in await _repository.accountIds()) {
      results.add(await syncAccount(id, request: request));
    }
    return BankSyncSummary(results);
  }

  Future<T> _retry<T>(Future<T> Function() action, Stopwatch watch) async {
    for (var attempt = 0; ; attempt++) {
      final remaining = limits.timeout - watch.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('Sync deadline');
      try {
        return await action().timeout(remaining);
      } on EnableBankingException catch (error) {
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
  }) async {
    final result = BankSyncResult(
      accountId: id,
      status: status,
      rejected: rejected,
      warnings: [warning],
    );
    try {
      await _repository.recordFailure(result);
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
    final watch = Stopwatch()..start();
    try {
      final context = await _repository.readContext(accountId);
      if (context.connection.status != BankConnectionStatus.active ||
          context.connection.sessionId == null ||
          context.account.ebAccountUid == null ||
          await _applicationId() != context.connection.applicationId) {
        return _failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'consent_or_credentials_unavailable',
        );
      }
      final scale = BankMoney.scales[context.currency];
      if (scale == null || scale > 2) {
        return _failure(
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
        () => _api.getAspsps(country: context.connection.aspspCountry),
        watch,
      );
      final matches = banks
          .where(
            (bank) =>
                bank.name == context.connection.aspspName &&
                bank.country == context.connection.aspspCountry,
          )
          .toList();
      if (matches.length != 1) {
        return _failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'bank_metadata_unavailable',
        );
      }
      final requiredHeaders = matches.single.requiredPsuHeaders;
      final headers = request.headersFor(requiredHeaders);
      final uid = context.account.ebAccountUid!;
      final details = await _retry(
        () => _api.getAccountDetails(uid, psuHeaders: headers),
        watch,
      );
      if (details.currency != context.currency) {
        return _failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'account_currency_mismatch',
        );
      }
      if (details.stableHashes.isNotEmpty &&
          !details.stableHashes.contains(context.account.identificationHash)) {
        return _failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'account_identity_mismatch',
        );
      }
      final warnings = <String>[];
      var strategy = context.checkpoint == null ? 'longest' : 'default';
      var dateFrom = context.checkpoint?.subtract(const Duration(days: 7));
      if (dateFrom != null && dateFrom.isAfter(now)) {
        dateFrom = null;
        strategy = 'longest';
        warnings.add('future_checkpoint_reset');
      }
      final items = <BankRemoteTransaction>[];
      final seenKeys = <String>{};
      String? continuation;
      DateTime? serverTime;
      var rejected = 0;
      var rawCount = 0;
      var fallback = false;
      for (var pageIndex = 0; ; pageIndex++) {
        if (pageIndex >= limits.pages) {
          return _failure(
            accountId,
            BankSyncStatus.retryableFailure,
            'page_limit',
          );
        }
        EbTransactionsPage page;
        try {
          page = await _retry(
            () => _api.getTransactions(
              uid,
              dateFrom: dateFrom,
              continuationKey: continuation,
              strategy: strategy,
              psuHeaders: headers,
            ),
            watch,
          );
        } on EnableBankingException catch (error) {
          if (pageIndex == 0 &&
              !fallback &&
              const {
                'WRONG_TRANSACTIONS_PERIOD',
                'DATE_FROM_IN_FUTURE',
              }.contains(error.error)) {
            fallback = true;
            strategy = 'default';
            dateFrom = null;
            warnings.add('bank_default_history_fallback');
            page = await _retry(
              () => _api.getTransactions(
                uid,
                strategy: strategy,
                psuHeaders: headers,
              ),
              watch,
            );
          } else {
            rethrow;
          }
        }
        if (page.serverTime != null) {
          serverTime ??= page.serverTime;
          if (page.serverTime!.difference(serverTime!).abs() >
              limits.timeout + const Duration(minutes: 1)) {
            return _failure(
              accountId,
              BankSyncStatus.retryableFailure,
              'server_clock_changed',
            );
          }
        }
        rawCount += page.transactions.length + page.rejectedRecords;
        if (rawCount > limits.records) {
          return _failure(
            accountId,
            BankSyncStatus.retryableFailure,
            'record_limit',
          );
        }
        rejected += page.rejectedRecords;
        for (final transaction in page.transactions) {
          try {
            final item = BankRemoteTransaction.fromTransaction(
              transaction,
              context.currency,
            );
            final serverDay = serverTime == null
                ? null
                : DateTime.utc(
                    serverTime.year,
                    serverTime.month,
                    serverTime.day,
                  );
            if (item.status == 'BOOK' &&
                serverDay != null &&
                item.date.isAfter(serverDay)) {
              throw const FormatException('Future booked date');
            }
            items.add(item);
          } on FormatException {
            rejected++;
          }
        }
        continuation = page.continuationKey;
        if (continuation == null) break;
        if (!seenKeys.add(continuation)) {
          return _failure(
            accountId,
            BankSyncStatus.retryableFailure,
            'continuation_cycle',
          );
        }
      }
      if (rejected > 0) {
        return _failure(
          accountId,
          BankSyncStatus.partial,
          'invalid_financial_records',
          rejected: rejected,
        );
      }
      final unique = <String>{};
      if (items.any((item) => !unique.add(item.key))) {
        return _failure(
          accountId,
          BankSyncStatus.partial,
          'ambiguous_transaction_identity',
        );
      }
      final balances = await _retry(
        () => _api.getBalances(uid, psuHeaders: headers),
        watch,
      );
      final balance = selectBankBalance(
        balances,
        items,
        context.currency,
        serverTime,
      );
      if (balance == null) {
        warnings.add('no_comparable_booked_balance');
        if (!context.initialized) {
          return _failure(
            accountId,
            BankSyncStatus.partial,
            'initial_balance_unverified',
          );
        }
      }
      if (serverTime == null) {
        return _failure(
          accountId,
          BankSyncStatus.retryableFailure,
          'missing_server_clock',
        );
      }
      if (context.connection.validUntil == null ||
          !context.connection.validUntil!.isAfter(serverTime)) {
        return _failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'consent_expired',
        );
      }
      if (watch.elapsed >= limits.timeout) {
        throw TimeoutException('Sync deadline');
      }
      if (await _applicationId() != context.connection.applicationId) {
        return _failure(
          accountId,
          BankSyncStatus.terminalFailure,
          'credentials_changed',
        );
      }
      return await _repository.commit(
        context,
        items,
        serverTime: serverTime,
        strategy: strategy,
        requestedFrom: dateFrom,
        requiredPsuHeaders: requiredHeaders,
        balance: balance,
        warnings: warnings,
      );
    } on EnableBankingException catch (error) {
      return _failure(
        accountId,
        error.isRetryable
            ? BankSyncStatus.retryableFailure
            : BankSyncStatus.terminalFailure,
        'api_${error.kind.name}',
      );
    } on TimeoutException {
      return _failure(
        accountId,
        BankSyncStatus.retryableFailure,
        'operation_timeout',
      );
    } on FormatException {
      return _failure(
        accountId,
        BankSyncStatus.partial,
        'invalid_or_changed_sync_context',
      );
    } on TypeError {
      return _failure(
        accountId,
        BankSyncStatus.partial,
        'invalid_response_schema',
      );
    } on DatabaseException {
      return _failure(
        accountId,
        BankSyncStatus.retryableFailure,
        'database_commit_failed',
      );
    } finally {
      watch.stop();
    }
  }
}
