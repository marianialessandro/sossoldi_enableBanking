import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

import 'enable_banking_credentials_store.dart';

const _kIssuer = 'enablebanking.com';
const _kAudience = 'api.enablebanking.com';
const _kMaxTtl = Duration(hours: 24);
const _kRefreshMargin = Duration(minutes: 5);

class EnableBankingAuthException implements Exception {
  final String message;

  const EnableBankingAuthException(this.message);

  @override
  String toString() => 'EnableBankingAuthException: $message';
}

// Signs requests with an RS256 JWT built from the user's BYOC key,
// on-device; the signed token is cached in memory only, never persisted.
class EnableBankingAuth {
  final Duration _tokenTtl;
  final Duration _refreshMargin;
  final DateTime Function() _now;

  String? _cachedToken;
  DateTime? _cachedExpiry;

  EnableBankingAuth({
    Duration tokenTtl = const Duration(hours: 1),
    Duration refreshMargin = _kRefreshMargin,
    DateTime Function() now = DateTime.now,
  }) : _tokenTtl = tokenTtl,
       _refreshMargin = refreshMargin,
       _now = now;

  String buildJwt({
    required String appId,
    required String privateKeyPem,
    Duration ttl = const Duration(hours: 1),
  }) {
    assert(ttl <= _kMaxTtl, 'ttl must not exceed 24h');

    final RSAPrivateKey key;
    try {
      key = RSAPrivateKey(privateKeyPem);
    } catch (_) {
      throw const EnableBankingAuthException('Invalid private key');
    }

    final jwt = JWT(
      {'iss': _kIssuer, 'aud': _kAudience},
      header: {'kid': appId},
    );

    try {
      return jwt.sign(key, algorithm: JWTAlgorithm.RS256, expiresIn: ttl);
    } catch (e) {
      throw EnableBankingAuthException('Could not sign the request: $e');
    }
  }

  Future<String> getValidToken(EnableBankingCredentialsStore store) async {
    final now = _now();
    final cachedExpiry = _cachedExpiry;
    if (_cachedToken != null &&
        cachedExpiry != null &&
        cachedExpiry.isAfter(now.add(_refreshMargin))) {
      return _cachedToken!;
    }

    final (config, privateKeyPem) = await store.readCredentials();
    if (config == null || privateKeyPem == null) {
      throw const EnableBankingAuthException(
        'Enable Banking credentials are not configured',
      );
    }

    final token = buildJwt(
      appId: config.appId,
      privateKeyPem: privateKeyPem,
      ttl: _tokenTtl,
    );

    _cachedToken = token;
    _cachedExpiry = now.add(_tokenTtl);
    return token;
  }

  // Must be called when credentials are cleared or regenerated, otherwise a
  // still-cached token keeps authenticating with revoked credentials.
  void invalidate() {
    _cachedToken = null;
    _cachedExpiry = null;
  }
}
