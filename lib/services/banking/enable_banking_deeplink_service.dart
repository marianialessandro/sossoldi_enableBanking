import 'dart:async';

import 'package:app_links/app_links.dart';

import 'enable_banking_config.dart';

final Uri _redirect = Uri.parse(kEbRedirectUri);

/// Query of a `sossoldi://eb-callback` deep link: what the bank sends back
/// once the user has approved (or refused) the consent.
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

  /// User facing reason why the authorization did not go through.
  String get errorMessage =>
      errorDescription ?? error ?? 'Authorization was not completed';
}

/// Source of incoming deep links: wraps `app_links` behind an interface so
/// the callback plumbing can be unit tested without platform channels.
abstract class UriLinkSource {
  /// Links delivered while the app is already running.
  Stream<Uri> get uriStream;

  /// Link the app was cold started with, if any.
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

/// Captures the Enable Banking OAuth callback, both while the app is alive
/// (foreground/background) and when the link is what started it.
class EnableBankingDeeplinkService {
  final UriLinkSource _source;

  StreamSubscription<Uri>? _subscription;
  bool _initialLinkChecked = false;
  String? _lastHandled;

  EnableBankingDeeplinkService({UriLinkSource? source})
    : _source = source ?? AppLinksUriSource();

  /// Returns the parsed callback, or null if [uri] is not the Enable Banking
  /// redirect (other deep links are none of our business).
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

  /// Starts routing callbacks to [onCallback]. Safe to call more than once:
  /// the stream is subscribed and the cold start link consumed only once.
  Future<void> start(void Function(EnableBankingCallback) onCallback) async {
    _subscription ??= _source.uriStream.listen(
      (uri) => _dispatch(uri, onCallback),
    );

    if (_initialLinkChecked) return;
    _initialLinkChecked = true;

    final initial = await _source.getInitialUri();
    if (initial != null) _dispatch(initial, onCallback);
  }

  void _dispatch(Uri uri, void Function(EnableBankingCallback) onCallback) {
    // On some platforms `app_links` also replays the launch link on the
    // stream: skip an URI identical to the previous one so a cold start
    // doesn't spend the same authorization code twice.
    if (uri.toString() == _lastHandled) return;

    final callback = parse(uri);
    if (callback == null) return;

    _lastHandled = uri.toString();
    onCallback(callback);
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
