import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/banking_persistence_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory documents;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUpAll(() async {
    documents = await Directory.systemTemp.createTemp('bank-persistence-docs-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => documents.path);
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      expect(await documents.list().toList(), isEmpty);
    } finally {
      await documents.delete(recursive: true);
    }
  });
  bankingPersistenceContract(databaseFactoryFfi);
}
