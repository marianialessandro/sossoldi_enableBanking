import 'dart:async';

import 'package:app_links/app_links.dart';

import 'enable_banking_config.dart';

class EnableBankingCallback {
  final String? code;
  final String? state;
  final String? error;
  final String? errorDescription;

  const EnableBankingCallback({
    this.code,
    this.state,
    this.error,
    this.errorDescription,
  });

  bool get isSuccess => code != null && error == null;
}

enum CallbackDisposition { terminal, retryable }

abstract class UriLinkSource {
  Stream<Uri> get uriStream;

  Future<Uri?> getInitialUri();
}

class AppLinksUriSource implements UriLinkSource {
  final AppLinks _appLinks;

  AppLinksUriSource({AppLinks? appLinks}) : _appLinks = appLinks ?? AppLinks();

  @override
  Stream<Uri> get uriStream => _appLinks.uriLinkStream;

  @override
  Future<Uri?> getInitialUri() => _appLinks.getInitialLink();
}

class EnableBankingDeeplinkService {
  final UriLinkSource _source;

  StreamSubscription<Uri>? _subscription;
  bool _initialLinkChecked = false;
  final Set<String> _handled = {};
  final Set<String> _inFlight = {};

  EnableBankingDeeplinkService({UriLinkSource? source})
    : _source = source ?? AppLinksUriSource();

  static EnableBankingCallback? parse(Uri uri) {
    final redirect = validateEnableBankingRedirect(kEbRedirectUri);
    if (uri.scheme != redirect.scheme ||
        uri.host != redirect.host ||
        uri.path.isNotEmpty) {
      return null;
    }
    final params = uri.queryParameters;
    return EnableBankingCallback(
      code: params['code'],
      state: params['state'],
      error: params['error'],
      errorDescription: params['error_description'],
    );
  }

  Future<void> start(
    Future<CallbackDisposition> Function(EnableBankingCallback) onCallback, {
    Future<void> Function(Object error)? onError,
  }) async {
    _subscription ??= _source.uriStream.listen(
      (uri) => unawaited(_dispatch(uri, onCallback, onError)),
      onError: (Object error) => unawaited(_notifyError(error, onError)),
    );
    if (_initialLinkChecked) return;
    _initialLinkChecked = true;
    try {
      final initial = await _source.getInitialUri();
      if (initial != null) await _dispatch(initial, onCallback, onError);
    } catch (error) {
      await _notifyError(error, onError);
    }
  }

  Future<void> _dispatch(
    Uri uri,
    Future<CallbackDisposition> Function(EnableBankingCallback) onCallback,
    Future<void> Function(Object error)? onError,
  ) async {
    final key = uri.toString();
    if (_handled.contains(key) || !_inFlight.add(key)) return;
    try {
      final callback = parse(uri);
      if (callback == null) return;
      final disposition = await onCallback(callback);
      if (disposition == CallbackDisposition.terminal) _handled.add(key);
    } catch (error) {
      await _notifyError(error, onError);
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<void> _notifyError(
    Object error,
    Future<void> Function(Object error)? onError,
  ) async {
    if (onError != null) await onError(error);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
