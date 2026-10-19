import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/banking_ui_provider.dart';
import '../../../ui/device.dart';
import '../../../services/banking/lifecycle/pending_bank_authorization.dart';

import '../../../model/bank_connection.dart';
import '../../../ui/widgets/native_alert_dialog.dart';

class ConfirmDisconnectDialog extends StatelessWidget {
  final BankConnection connection;
  final VoidCallback? onPressed;
  const ConfirmDisconnectDialog({
    required this.connection,
    this.onPressed,
    super.key,
  });
  @override
  Widget build(BuildContext context) => _RecoveryConfirmation(
    title: 'Disconnect and revoke consent?',
    body:
        'Disconnect ${connection.institutionName} and revoke its remote consent? Your imported accounts and transaction history stay in Sossoldi. The accounts become manual accounts and stop syncing.',
    negative: 'Keep connection',
    positive: 'Disconnect and revoke',
    onPressed: onPressed,
  );
}

class ConfirmLocalDisconnectDialog extends StatelessWidget {
  final BankConnection connection;
  const ConfirmLocalDisconnectDialog({required this.connection, super.key});
  @override
  Widget build(BuildContext context) => _RecoveryConfirmation(
    title: 'Disconnect locally only?',
    body:
        'Disconnect ${connection.institutionName} from Sossoldi only? Your imported accounts and transaction history stay here as manual accounts and stop syncing. This does not revoke remote consent, which may still be active. Manage or revoke it through your bank or Enable Banking.',
    negative: 'Keep connection',
    positive: 'Disconnect locally',
  );
}

class ConfirmCancelAuthorizationDialog extends StatelessWidget {
  final String bankName;
  const ConfirmCancelAuthorizationDialog({required this.bankName, super.key});
  @override
  Widget build(BuildContext context) => _RecoveryConfirmation(
    title: 'Cancel connection attempt?',
    body:
        'Stop connecting to $bankName? You can then choose another bank. This does not revoke any consent already granted or delete imported accounts or transactions.',
    negative: 'Keep attempt',
    positive: 'Cancel attempt',
  );
}

class _RecoveryConfirmation extends StatelessWidget {
  final String title;
  final String body;
  final String negative;
  final String positive;
  final VoidCallback? onPressed;
  const _RecoveryConfirmation({
    required this.title,
    required this.body,
    required this.negative,
    required this.positive,
    this.onPressed,
  });
  @override
  Widget build(BuildContext context) => AdaptiveDialog(
    scrollable: true,
    title: Text(title),
    content: SingleChildScrollView(
      child: Text(
        body,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    ),
    actions: [
      AdaptiveDialogAction(
        autofocus: true,
        child: Text(negative),
        onPressed: () => Navigator.of(context).pop(false),
      ),
      AdaptiveDialogAction(
        child: Text(positive),
        isDestructiveAction: true,
        onPressed: onPressed ?? () => Navigator.of(context).pop(true),
      ),
    ],
  );
}

class AuthorizationRecoveryControls extends ConsumerStatefulWidget {
  final VoidCallback? onResumed;
  const AuthorizationRecoveryControls({this.onResumed, super.key});
  @override
  ConsumerState<AuthorizationRecoveryControls> createState() =>
      _AuthorizationRecoveryControlsState();
}

class _AuthorizationRecoveryControlsState
    extends ConsumerState<AuthorizationRecoveryControls> {
  bool _cancelling = false;
  final _cancelFocus = FocusNode(debugLabel: 'Cancel attempt');
  @override
  void dispose() {
    _cancelFocus.dispose();
    super.dispose();
  }

  Future<void> _cancel() async {
    final flow = ref.read(connectBankFlowProvider.notifier);
    final expected =
        ref.read(connectBankFlowProvider).authorizationOwner ??
        await flow.captureAuthorizationOwner();
    if (expected == null || !mounted) return;
    _cancelFocus.requestFocus();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) =>
          ConfirmCancelAuthorizationDialog(bankName: expected.bankName),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _cancelling = true);
    try {
      await flow.cancelAuthorization(expected);
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  Future<void> _resume() async {
    final flow = ref.read(connectBankFlowProvider.notifier);
    final expected =
        ref.read(connectBankFlowProvider).authorizationOwner ??
        await flow.captureAuthorizationOwner();
    if (expected == null || !mounted) return;
    final result = await flow.resumeAuthorization(expected);
    if (mounted &&
        result != null &&
        result.opened &&
        flow.isAuthorizationResultCurrent(result)) {
      widget.onResumed?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(connectBankFlowProvider);
    final owner = state.authorizationOwner;
    if (owner == null) return const SizedBox.shrink();
    final credentials = ref.watch(enableBankingSettingsProvider).value;
    final canResume =
        owner.pending?.phase == PendingAuthorizationPhase.awaitingCallback &&
        credentials?.appId == owner.pending?.applicationId &&
        state.pendingCleanup == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            _cancelling
                ? 'Cancelling connection attempt…'
                : state.authorizing
                ? 'Starting bank connection…'
                : 'Waiting for bank authorization',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        const SizedBox(height: Sizes.lg),
        Text(owner.bankName),
        const SizedBox(height: Sizes.lg),
        if (owner.pending?.phase == PendingAuthorizationPhase.awaitingCallback)
          TextButton(
            onPressed: _cancelling || state.authorizing || !canResume
                ? null
                : _resume,
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            child: const Text('Try again'),
          ),
        TextButton(
          focusNode: _cancelFocus,
          onPressed: _cancelling ? null : _cancel,
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          child: Semantics(
            label: 'Cancel connection attempt for ${owner.bankName}',
            child: const Text('Cancel attempt'),
          ),
        ),
      ],
    );
  }
}
