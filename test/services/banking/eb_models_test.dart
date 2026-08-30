import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sossoldi/services/banking/enable_banking_exception.dart';
import 'package:sossoldi/services/banking/models/aspsp.dart';
import 'package:sossoldi/services/banking/models/eb_account.dart';
import 'package:sossoldi/services/banking/models/eb_balance.dart';
import 'package:sossoldi/services/banking/models/eb_session.dart';
import 'package:sossoldi/services/banking/models/eb_transaction.dart';
import 'package:sossoldi/services/banking/models/eb_transactions_page.dart';

Map<String, dynamic> _loadJson(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('Aspsp.fromJson', () {
    test('parses fields including psu_types and nested sandbox', () {
      final aspsp = Aspsp.fromJson(_loadJson('eb_aspsp.json'));

      expect(aspsp.name, 'Mock ASPSP');
      expect(aspsp.country, 'IT');
      expect(aspsp.logo, 'https://example.com/logo.png');
      expect(aspsp.psuTypes, ['personal', 'business']);
      expect(aspsp.maximumConsentValidity, 7776000);
      expect(aspsp.beta, false);
      expect(aspsp.sandbox, isNotNull);
      expect(aspsp.sandbox!.users, isNotEmpty);
    });

    test('null sandbox and missing psu_types are handled', () {
      final aspsp = Aspsp.fromJson({'name': 'X', 'country': 'FR'});

      expect(aspsp.sandbox, isNull);
      expect(aspsp.psuTypes, isEmpty);
      expect(aspsp.beta, false);
      expect(aspsp.maximumConsentValidity, isNull);
    });
  });

  group('EbAccount.fromJson', () {
    test('reads nested account_id.iban', () {
      final account = EbAccount.fromJson(_loadJson('eb_account.json'));

      expect(account.uid, 'acc-uid-123');
      expect(account.iban, 'IT60X0542811101000000123456');
      expect(account.name, 'Main Account');
      expect(account.currency, 'EUR');
      expect(account.cashAccountType, 'CACC');
      expect(account.usage, 'PRIV');
      expect(account.identificationHash, 'idhash-abc');
    });

    test('missing account_id yields null iban', () {
      final account = EbAccount.fromJson({'uid': 'only-uid'});

      expect(account.uid, 'only-uid');
      expect(account.iban, isNull);
    });
  });

  group('EbBalance.fromJson', () {
    test('parses string amount into num', () {
      final balance = EbBalance.fromJson(_loadJson('eb_balance.json'));

      expect(balance.name, 'Closing booked');
      expect(balance.balanceAmount.amount, 1234.56);
      expect(balance.balanceAmount.currency, 'EUR');
      expect(balance.balanceType, 'CLBD');
    });
  });

  group('EbTransaction.fromJson', () {
    Map<String, dynamic> validTransaction() => {
      'entry_reference': 'ref-001',
      'status': 'BOOK',
      'transaction_amount': {'amount': '10.33', 'currency': 'EUR'},
      'credit_debit_indicator': 'CRDT',
    };

    test('parses a well-formed transaction', () {
      final tx = EbTransaction.fromJson(validTransaction());

      expect(tx.status, 'BOOK');
      expect(tx.transactionAmount.amount, 10.33);
      expect(tx.creditDebitIndicator, 'CRDT');
    });

    test('throws EnableBankingException instead of a raw TypeError when '
        'credit_debit_indicator is missing', () {
      final json = validTransaction()..remove('credit_debit_indicator');

      expect(
        () => EbTransaction.fromJson(json),
        throwsA(isA<EnableBankingException>()),
      );
    });

    test('throws EnableBankingException instead of a raw TypeError when '
        'transaction_amount is null', () {
      final json = validTransaction()..['transaction_amount'] = null;

      expect(
        () => EbTransaction.fromJson(json),
        throwsA(isA<EnableBankingException>()),
      );
    });

    test('throws EnableBankingException instead of a raw TypeError when '
        'status is missing', () {
      final json = validTransaction()..remove('status');

      expect(
        () => EbTransaction.fromJson(json),
        throwsA(isA<EnableBankingException>()),
      );
    });
  });

  group('EbTransactionsPage.fromJson', () {
    late EbTransactionsPage page;

    setUp(() {
      page = EbTransactionsPage.fromJson(_loadJson('eb_transactions.json'));
    });

    test('parses envelope with continuation_key', () {
      expect(page.continuationKey, 'next-page-123');
      expect(page.transactions.length, 2);
    });

    test('credit transaction: positive signedAmount, stableId, isBooked', () {
      final credit = page.transactions[0];

      expect(credit.transactionAmount.amount, 10.33);
      expect(credit.signedAmount, 10.33);
      expect(credit.creditDebitIndicator, 'CRDT');
      expect(credit.stableId, 'ref-001');
      expect(credit.isBooked, isTrue);
      expect(credit.creditorName, 'Alice');
      expect(credit.debtorName, 'Bob');
      expect(credit.remittanceInformation, ['Salary', 'January']);
      expect(credit.bookingDate, DateTime.parse('2025-01-15'));
    });

    test('debit transaction: negative signedAmount, fallback stableId', () {
      final debit = page.transactions[1];

      expect(debit.signedAmount, -25.00);
      expect(debit.creditDebitIndicator, 'DBIT');
      expect(debit.stableId, 'tx-002');
      expect(debit.isBooked, isFalse);
      expect(debit.bookingDate, isNull);
      expect(debit.note, 'supermarket');
    });

    test('skips a malformed transaction instead of failing the whole page, '
        'keeping the valid ones from the same page', () {
      final malformedPage = EbTransactionsPage.fromJson({
        'transactions': [
          {
            'entry_reference': 'ref-good',
            'status': 'BOOK',
            'transaction_amount': {'amount': '5.00', 'currency': 'EUR'},
            'credit_debit_indicator': 'CRDT',
          },
          {'entry_reference': 'ref-bad', 'status': 'BOOK'},
        ],
      });

      expect(malformedPage.transactions, hasLength(1));
      expect(malformedPage.transactions.single.stableId, 'ref-good');
    });
  });

  group('EbSession.fromJson', () {
    test('reads nested aspsp and access.valid_until', () {
      final session = EbSession.fromJson(_loadJson('eb_session.json'));

      expect(session.sessionId, 'sess-789');
      expect(session.aspspName, 'Mock ASPSP');
      expect(session.aspspCountry, 'IT');
      expect(session.psuType, 'personal');
      expect(session.validUntil, DateTime.parse('2025-04-15T10:00:00.000Z'));
      expect(session.accounts.length, 1);
      expect(session.accounts.first.iban, 'IT60X0542811101000000123456');
    });
  });
}
