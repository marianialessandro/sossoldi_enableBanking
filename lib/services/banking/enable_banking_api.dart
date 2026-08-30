import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'enable_banking_auth.dart';
import 'enable_banking_config.dart';
import 'enable_banking_credentials_store.dart';
import 'enable_banking_exception.dart';
import 'models/aspsp.dart';
import 'models/eb_auth.dart';
import 'models/eb_balance.dart';
import 'models/eb_session.dart';
import 'models/eb_transactions_page.dart';

const _kBaseUrl = 'https://api.enablebanking.com';

const _kRequestTimeout = Duration(seconds: 30);

String _formatDate(DateTime date) {
  final utc = date.toUtc();
  final year = utc.year.toString().padLeft(4, '0');
  final month = utc.month.toString().padLeft(2, '0');
  final day = utc.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

class EnableBankingApi {
  final EnableBankingAuth _auth;
  final EnableBankingCredentialsStore _store;
  final http.Client _client;

  final Duration _requestTimeout;

  EnableBankingApi({
    required EnableBankingAuth auth,
    required EnableBankingCredentialsStore store,
    http.Client? client,
    Duration requestTimeout = _kRequestTimeout,
  }) : _auth = auth,
       _store = store,
       _client = client ?? http.Client(),
       _requestTimeout = requestTimeout;

  Future<Map<String, String>> _headers() async => {
    'Authorization': 'Bearer ${await _auth.getValidToken(_store)}',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  void _check(http.Response response) {
    if (response.statusCode < 400) return;

    Map<String, dynamic>? body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      body = null;
    }
    throw EnableBankingException(
      statusCode: response.statusCode,
      error: body?['error'] as String?,
      message: body?['message'] as String?,
    );
  }

  // Converts a timeout or dropped connection into an EnableBankingException
  // so callers only need to handle one error type.
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_requestTimeout);
    } on TimeoutException {
      throw const EnableBankingException(message: 'Request timed out');
    } on SocketException catch (e) {
      throw EnableBankingException(message: e.message);
    }
  }

  // Same rationale as _send: a non-JSON body becomes an
  // EnableBankingException instead of a raw FormatException.
  Map<String, dynamic> _decode(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } on FormatException {
      throw const EnableBankingException(
        message: 'Unexpected response from Enable Banking',
      );
    }
  }

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String>? query,
  ]) async {
    final uri = Uri.parse('$_kBaseUrl$path').replace(
      queryParameters: query != null && query.isNotEmpty ? query : null,
    );
    final response = await _send(
      () async => _client.get(uri, headers: await _headers()),
    );
    _check(response);
    return _decode(response.body);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$_kBaseUrl$path');
    final response = await _send(
      () async =>
          _client.post(uri, headers: await _headers(), body: jsonEncode(body)),
    );
    _check(response);
    return _decode(response.body);
  }

  Future<void> _delete(String path) async {
    final uri = Uri.parse('$_kBaseUrl$path');
    final response = await _send(
      () async => _client.delete(uri, headers: await _headers()),
    );
    _check(response);
  }

  Future<List<Aspsp>> getAspsps({
    required String country,
    String psuType = 'personal',
  }) async {
    final json = await _get('/aspsps', {
      'country': country,
      'psu_type': psuType,
    });
    return ((json['aspsps'] as List?) ?? const [])
        .map((e) => Aspsp.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<EbAuthorization> startAuthorization({
    required String aspspName,
    required String aspspCountry,
    required String state,
    required DateTime validUntil,
    String redirectUri = kEbRedirectUri,
    String psuType = 'personal',
    String? language,
  }) async {
    final json = await _post('/auth', {
      'access': {
        'valid_until': validUntil.toUtc().toIso8601String(),
        'balances': true,
        'transactions': true,
      },
      'aspsp': {'name': aspspName, 'country': aspspCountry},
      'state': state,
      'redirect_url': redirectUri,
      'psu_type': psuType,
      'language': ?language,
    });
    return EbAuthorization.fromJson(json);
  }

  Future<EbSession> createSession(String code) async {
    final json = await _post('/sessions', {'code': code});
    return EbSession.fromJson(json);
  }

  Future<EbSession> getSession(String sessionId) async {
    final json = await _get('/sessions/$sessionId');
    return EbSession.fromJson(json);
  }

  Future<void> deleteSession(String sessionId) async {
    await _delete('/sessions/$sessionId');
  }

  Future<List<EbBalance>> getBalances(String accountUid) async {
    final json = await _get('/accounts/$accountUid/balances');
    return ((json['balances'] as List?) ?? const [])
        .map((e) => EbBalance.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<EbTransactionsPage> getTransactions(
    String accountUid, {
    DateTime? dateFrom,
    DateTime? dateTo,
    String? continuationKey,
    String? transactionStatus,
  }) async {
    final json = await _get('/accounts/$accountUid/transactions', {
      if (dateFrom != null) 'date_from': _formatDate(dateFrom),
      if (dateTo != null) 'date_to': _formatDate(dateTo),
      'continuation_key': ?continuationKey,
      'transaction_status': ?transactionStatus,
    });
    return EbTransactionsPage.fromJson(json);
  }
}
