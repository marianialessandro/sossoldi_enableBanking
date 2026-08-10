import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/services/banking/enable_banking_deeplink_service.dart';

/// Stands in for `app_links`: links are pushed by the test instead of
/// arriving from the platform channel.
class _FakeUriLinkSource implements UriLinkSource {
  final StreamController<Uri> controller = StreamController<Uri>.broadcast();
  Uri? initialUri;

  @override
  Stream<Uri> get uriStream => controller.stream;

  @override
  Future<Uri?> getInitialUri() async => initialUri;
}

void main() {
  late _FakeUriLinkSource source;
  late EnableBankingDeeplinkService service;
  late List<EnableBankingCallback> received;

  setUp(() {
    source = _FakeUriLinkSource();
    service = EnableBankingDeeplinkService(source: source);
    received = [];
  });

  tearDown(() {
    service.dispose();
    source.controller.close();
  });

  group('parse', () {
    test('extracts code and state from the callback', () {
      final callback = EnableBankingDeeplinkService.parse(
        Uri.parse('sossoldi://eb-callback?code=auth-code&state=csrf-1'),
      );

      expect(callback, isNotNull);
      expect(callback!.code, 'auth-code');
      expect(callback.state, 'csrf-1');
      expect(callback.isSuccess, isTrue);
    });

    test('extracts the error and its description', () {
      final callback = EnableBankingDeeplinkService.parse(
        Uri.parse(
          'sossoldi://eb-callback?error=access_denied'
          '&error_description=User%20refused',
        ),
      );

      expect(callback!.isSuccess, isFalse);
      expect(callback.error, 'access_denied');
      expect(callback.errorMessage, 'User refused');
    });

    test('a callback without code nor error is not a success', () {
      final callback = EnableBankingDeeplinkService.parse(
        Uri.parse('sossoldi://eb-callback'),
      );

      expect(callback!.isSuccess, isFalse);
      expect(callback.errorMessage, isNotEmpty);
    });

    test('ignores links that are not the Enable Banking redirect', () {
      expect(
        EnableBankingDeeplinkService.parse(
          Uri.parse('sossoldi://other-host?code=x'),
        ),
        isNull,
      );
      expect(
        EnableBankingDeeplinkService.parse(
          Uri.parse('https://example.com/eb-callback?code=x'),
        ),
        isNull,
      );
    });
  });

  group('start', () {
    test('routes links received while the app is running', () async {
      await service.start((cb) async => received.add(cb));

      source.controller.add(
        Uri.parse('sossoldi://eb-callback?code=one&state=csrf-1'),
      );
      source.controller.add(Uri.parse('sossoldi://unrelated'));
      await pumpEventQueue();

      expect(received, hasLength(1));
      expect(received.single.code, 'one');
    });

    test('routes the cold start link', () async {
      source.initialUri = Uri.parse(
        'sossoldi://eb-callback?code=cold&state=csrf-1',
      );

      await service.start((cb) async => received.add(cb));

      expect(received.single.code, 'cold');
    });

    test('does not spend the same link twice', () async {
      source.initialUri = Uri.parse(
        'sossoldi://eb-callback?code=cold&state=csrf-1',
      );

      await service.start((cb) async => received.add(cb));
      // Some platforms replay the launch link on the stream.
      source.controller.add(source.initialUri!);
      await pumpEventQueue();

      expect(received, hasLength(1));
    });

    test('calling start twice keeps a single subscription', () async {
      await service.start((cb) async => received.add(cb));
      await service.start((cb) async => received.add(cb));

      source.controller.add(
        Uri.parse('sossoldi://eb-callback?code=one&state=csrf-1'),
      );
      await pumpEventQueue();

      expect(received, hasLength(1));
    });

    test('stops routing after dispose', () async {
      await service.start((cb) async => received.add(cb));
      service.dispose();

      source.controller.add(
        Uri.parse('sossoldi://eb-callback?code=one&state=csrf-1'),
      );
      await pumpEventQueue();

      expect(received, isEmpty);
    });

    test('an onCallback failure is swallowed instead of becoming an unhandled '
        'async error, and later distinct links still get through', () async {
      var calls = 0;
      await service.start((_) async {
        calls++;
        throw StateError('boom');
      });

      source.controller.add(
        Uri.parse('sossoldi://eb-callback?code=one&state=csrf-1'),
      );
      await pumpEventQueue();
      source.controller.add(
        Uri.parse('sossoldi://eb-callback?code=two&state=csrf-2'),
      );
      await pumpEventQueue();

      expect(calls, 2);
    });
  });
}
