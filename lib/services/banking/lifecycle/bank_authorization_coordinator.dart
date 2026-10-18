import 'dart:async';

import '../banking_exception.dart';
import '../bank_authorization_cleanup.dart';

export '../bank_authorization_cleanup.dart';
import 'bank_authorization_result.dart';

/// Scope belongs to the storage backend, rather than to a service or widget.
abstract interface class BankAuthorizationScope {
  Object get authorizationScope;
}

abstract interface class BankAuthorizationCleanupStore {
  Future<List<ObsoleteBankConnection>> readObsoleteConnections();
  Future<void> saveObsoleteConnection(ObsoleteBankConnection connection);
  Future<void> removeObsoleteConnection(ObsoleteBankConnection connection);
}

typedef ObsoleteBankConnectionHandler =
    Future<bool> Function(ObsoleteBankConnection connection);

/// The reference stays available even if both storage and remote cleanup fail.
class ObsoleteBankAuthorizationException extends BankingException {
  final ObsoleteBankConnection connection;
  final bool cleanupConfirmed;
  final bool referencePersisted;
  final bool localCleanupConfirmed;

  const ObsoleteBankAuthorizationException({
    required this.connection,
    required this.cleanupConfirmed,
    required this.referencePersisted,
    this.localCleanupConfirmed = true,
  }) : super(providerId: 'application', failure: BankingFailure.rejected);
}

class BankAuthorizationCoordinator {
  static final _scopes = Expando<BankAuthorizationCoordinator>();

  factory BankAuthorizationCoordinator.forScope(Object scope) =>
      _scopes[scope] ??= BankAuthorizationCoordinator._();

  BankAuthorizationCoordinator._();

  int revision = 0;
  final unresolvedConnections = <ObsoleteBankConnection>[];
  Future<void>? _commits;
  Future<void>? _callbacks;
  Future<void>? _cleanup;
  Future<AuthorizationAttempt>? _start;
  Object? _startKey;
  Future<Object>? _startContextKey;

  void invalidate() {
    ++revision;
    _start = null;
    _startKey = null;
    _startContextKey = null;
  }

  Future<T> commit<T>(Future<T> Function() operation) {
    final result = (_commits ?? Future<void>.value()).then((_) => operation());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _commits = tail;
    unawaited(
      tail.then((_) {
        if (identical(_commits, tail)) _commits = null;
      }),
    );
    return result;
  }

  Future<T> callback<T>(Future<T> Function() operation) {
    final result = (_callbacks ?? Future<void>.value()).then(
      (_) => operation(),
    );
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _callbacks = tail;
    unawaited(
      tail.then((_) {
        if (identical(_callbacks, tail)) _callbacks = null;
      }),
    );
    return result;
  }

  Future<T> cleanup<T>(Future<T> Function() operation) {
    final result = (_cleanup ?? Future<void>.value()).then((_) => operation());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _cleanup = tail;
    unawaited(
      tail.then((_) {
        if (identical(_cleanup, tail)) _cleanup = null;
      }),
    );
    return result;
  }

  Future<AuthorizationAttempt> start(
    Object key,
    Future<AuthorizationAttempt> Function() operation, {
    required Future<Object> Function() readContextKey,
  }) {
    if (_start case final current?) {
      if (_startKey == key) {
        final contextKey = _startContextKey!;
        return Future.wait([
          contextKey,
          Future<Object>.sync(readContextKey),
        ]).then((keys) {
          if (keys[0] != keys[1]) {
            throw const BankingException(
              providerId: 'application',
              failure: BankingFailure.rejected,
            );
          }
          return current;
        });
      }
      return Future.error(
        const BankingException(
          providerId: 'application',
          failure: BankingFailure.rejected,
        ),
      );
    }
    _startKey = key;
    final contextKey = Future<Object>.sync(readContextKey);
    _startContextKey = contextKey;
    final result = contextKey.then((_) => operation());
    _start = result;
    void release() {
      if (identical(_start, result)) {
        _start = null;
        _startKey = null;
        _startContextKey = null;
      }
    }

    unawaited(
      result.then<void>(
        (_) => release(),
        onError: (Object _, StackTrace _) => release(),
      ),
    );
    return result;
  }
}
