import 'dart:async';

import 'package:flutter/widgets.dart';

import 'enable_banking_sync_service.dart';
import 'models/bank_sync_result.dart';

/// Startup/resume synchronization, activated by the future banking UI integration.
class BankSyncLifecycle with WidgetsBindingObserver {
  final EnableBankingSyncService service;
  final void Function(BankSyncSummary) onResult;
  final void Function(Object) onError;
  bool _started = false;
  bool _running = false;

  BankSyncLifecycle({
    required this.service,
    required this.onResult,
    required this.onError,
  });

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_sync());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_started && state == AppLifecycleState.resumed) unawaited(_sync());
  }

  Future<void> _sync() async {
    if (_running) return;
    _running = true;
    try {
      final result = await service.syncAll();
      if (_started) onResult(result);
    } catch (error) {
      if (_started) onError(error);
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
  }
}
