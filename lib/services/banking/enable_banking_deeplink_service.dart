import 'dart:async';

import 'package:app_links/app_links.dart';

import 'enable_banking_config.dart';

final Uri _redirect = Uri.parse(kEbAppCallbackUri);

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

  bool get isSuccess => error == null && code != null;

  String get errorMessage =>
      errorDescription ?? error ?? 'Authorization was not completed';
}

// Wraps `app_links` behind an interface so the callback plumbing can be
// unit tested without platform channels.
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
  String? _lastHandled;

  EnableBankingDeeplinkService({UriLinkSource? source})
    : _source = source ?? AppLinksUriSource();

  static EnableBankingCallback? parse(Uri uri) {
    if (uri.scheme != _redirect.scheme || uri.host != _redirect.host) {
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

  // Safe to call more than once: the stream is subscribed and the cold
  // start link consumed only once.
  Future<void> start(
    Future<void> Function(EnableBankingCallback) onCallback,
  ) async {
    _subscription ??= _source.uriStream.listen(
      (uri) => _dispatch(uri, onCallback),
    );

    if (_initialLinkChecked) return;
    _initialLinkChecked = true;

    final initial = await _source.getInitialUri();
    if (initial != null) await _dispatch(initial, onCallback);
  }

  Future<void> _dispatch(
    Uri uri,
    Future<void> Function(EnableBankingCallback) onCallback,
  ) async {
    // app_links can replay the launch link, so skip a URI identical to the
    // previous one to avoid spending the same code twice.
    if (uri.toString() == _lastHandled) return;

    final callback = parse(uri);
    if (callback == null) return;

    _lastHandled = uri.toString();
    try {
      await onCallback(callback);
    } catch (_) {
      // Safety net: onCallback should handle its own errors; this only
      // avoids an unhandled async error.
    }
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
