import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/banking_ui_provider.dart';
import '../../ui/device.dart';
import '../../ui/widgets/default_container.dart';
import '../../ui/widgets/rounded_icon.dart';
import 'widgets/aspsp_selector.dart';
import 'widgets/connection_card.dart';
import 'widgets/confirm_disconnect_dialog.dart';
import 'widgets/country_selector.dart';
import 'banking_import_context.dart';

/// Banking hub: the banks already linked, plus the entry point of the country → bank → consent flow.
class ConnectBankPage extends ConsumerStatefulWidget {
  const ConnectBankPage({super.key});

  @override
  ConsumerState<ConnectBankPage> createState() => _ConnectBankPageState();
}

class _ConnectBankPageState extends ConsumerState<ConnectBankPage> {
  final _noticeFocus = FocusNode(debugLabel: 'Bank recovery result');
  BankRecoveryActionResult? _focusedNotice;
  ConnectBankFlow? _flow;
  @override
  void initState() {
    super.initState();
    _flow = ref.read(connectBankFlowProvider.notifier);
    Future<void>.microtask(() async {
      if (mounted) {
        _flow!.dismissRecoveryNotice();
        await _flow!.refreshAuthorization();
      }
    });
  }

  @override
  void dispose() {
    _noticeFocus.dispose();
    super.dispose();
  }

  void _openSheet(Widget Function(ScrollController) builder) {
    showModalBottomSheet(
      context: context,
      clipBehavior: Clip.antiAliasWithSaveLayer,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(Sizes.borderRadius),
          topRight: Radius.circular(Sizes.borderRadius),
        ),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        minChildSize: 0.5,
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        builder: (_, controller) => builder(controller),
      ),
    );
  }

  void _selectCountry() => _openSheet(
    (controller) => CountrySelector(
      scrollController: controller,
      onSelected: _selectAspsp,
      supportedCountries:
          ref.read(enableBankingSettingsProvider).value?.supportedCountries ??
          const [],
    ),
  );

  void _selectAspsp(String countryCode) => _openSheet(
    (controller) =>
        AspspSelector(scrollController: controller, country: countryCode),
  );

  @override
  Widget build(BuildContext context) {
    final hasCredentials =
        ref.watch(enableBankingSettingsProvider).value != null;
    final flowState = ref.watch(connectBankFlowProvider);
    final notice = flowState.recoveryNotice;
    if (!identical(notice, _focusedNotice)) {
      _focusedNotice = notice;
      if (notice != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(_focusedNotice, notice)) {
            _noticeFocus.requestFocus();
          }
        });
      }
    }
    final connections = ref.watch(bankConnectionsProvider);
    final recoveryIssue = ref.watch(bankRecoveryIssueProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Connect bank'),
        actions: [
          IconButton(
            onPressed: hasCredentials && flowState.authorizationOwner == null
                ? _selectCountry
                : null,
            tooltip: 'Link a bank',
            icon: const Icon(Icons.add_circle),
            splashRadius: 28,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(top: Sizes.xl),
        physics: const BouncingScrollPhysics(),
        child: Column(
          children: [
            if (flowState.authorizationOwner != null)
              const DefaultContainer(child: AuthorizationRecoveryControls()),
            for (final notice in flowState.visibleRecoveryNotices)
              DefaultContainer(
                child: Focus(
                  focusNode: identical(notice, flowState.recoveryNotice)
                      ? _noticeFocus
                      : null,
                  child: Semantics(
                    liveRegion: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (notice.connection != null)
                          Text(notice.connection!.institutionName),
                        Text(
                          notice.message,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                        ),
                        const SizedBox(height: Sizes.lg),
                        if (notice.status == BankRecoveryActionStatus.failed &&
                            notice.kind == BankRecoveryActionKind.cancel)
                          const AuthorizationRecoveryControls(),
                        TextButton(
                          onPressed: () => ref
                              .read(connectBankFlowProvider.notifier)
                              .dismissRecoveryNotice(notice),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          child: const Text('Dismiss'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (flowState.pendingCleanup != null)
              DefaultContainer(
                child: TextButton(
                  onPressed: () => ref
                      .read(connectBankFlowProvider.notifier)
                      .retryPendingCleanup(flowState.pendingCleanup),
                  child: const Text('Retry cleanup'),
                ),
              ),
            if (recoveryIssue != null)
              DefaultContainer(
                child: Semantics(
                  liveRegion: true,
                  child: Column(
                    children: [
                      Text(recoveryIssue),
                      TextButton(
                        onPressed: () async {
                          await resumeBankImport(context, ref);
                          if (mounted) {
                            ref.invalidate(bankingUiBootstrapProvider);
                          }
                        },
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              ),
            if (!hasCredentials)
              DefaultContainer(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: Sizes.md,
                  children: [
                    Row(
                      spacing: Sizes.md,
                      children: [
                        Icon(
                          Icons.info,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                        Expanded(
                          child: Text(
                            "Configure your Enable Banking credentials first",
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(
                          context,
                        ).pushNamed('/enable-banking-setup'),
                        child: const Text("CONFIGURE"),
                      ),
                    ),
                  ],
                ),
              ),
            connections.when(
              data: (items) => items.isEmpty
                  ? flowState.authorizationOwner != null || notice != null
                        ? const SizedBox.shrink()
                        : const _NoBankLinked()
                  : ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: items.length,
                      itemBuilder: (context, i) => Container(
                        margin: const EdgeInsets.only(bottom: Sizes.lg),
                        child: ConnectionCard(
                          key: ValueKey(items[i].id),
                          connection: items[i],
                        ),
                      ),
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, stack) => Column(
                children: [
                  const Text('Could not load linked banks. Try again.'),
                  TextButton(
                    onPressed: () => ref.invalidate(bankConnectionsProvider),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoBankLinked extends StatelessWidget {
  const _NoBankLinked();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Sizes.xl),
      child: Column(
        spacing: Sizes.md,
        children: [
          RoundedIcon(
            icon: Icons.account_balance,
            backgroundColor: Theme.of(context).colorScheme.secondary,
            size: 40,
          ),
          Text(
            "No banks linked yet",
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          Text(
            "Tap + to link your first bank",
            style: Theme.of(context).textTheme.bodySmall!.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
