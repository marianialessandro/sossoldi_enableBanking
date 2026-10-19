import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../constants/style.dart';
import '../../../providers/banking_ui_provider.dart';
import '../../../services/banking/bank_institution.dart';
import '../../../ui/device.dart';
import '../../../ui/snack_bars/snack_bar.dart';
import '../../../ui/widgets/rounded_icon.dart';
import 'confirm_disconnect_dialog.dart';

/// Bottom sheet content: the banks available in the chosen country. Tapping one starts the Enable Banking authorization and hands the user over to the bank consent page in an external browser.
class AspspSelector extends ConsumerStatefulWidget {
  const AspspSelector({
    required this.scrollController,
    required this.country,
    super.key,
  });

  final ScrollController scrollController;
  final String country;

  @override
  ConsumerState<AspspSelector> createState() => _AspspSelectorState();
}

class _AspspSelectorState extends ConsumerState<AspspSelector> {
  bool loading = true;
  Object? _connectingOperation;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadAspsps();
  }

  Future<void> _loadAspsps() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await ref
          .read(connectBankFlowProvider.notifier)
          .loadAspsps(widget.country);
    } on EnableBankingException catch (e) {
      error = bankingErrorMessage(e);
    } on EnableBankingAuthException catch (e) {
      error = bankingErrorMessage(e);
    } catch (e) {
      error = bankingErrorMessage(e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _connect(BankInstitution aspsp) async {
    final flow = ref.read(connectBankFlowProvider.notifier);
    if (ref.read(connectBankFlowProvider).authorizationOwner != null) return;
    final operation = Object();
    _connectingOperation = operation;
    final credentials = ref
        .read(enableBankingCredentialsStoreProvider)
        .credentialRevision;
    final future = flow.startConnection(aspsp);
    final generation = flow.authorizationOperation;
    final expected = ref.read(connectBankFlowProvider).authorizationOwner;
    bool current() =>
        mounted &&
        identical(_connectingOperation, operation) &&
        expected != null &&
        ref
                .read(connectBankFlowProvider)
                .authorizationOwner
                ?.sameGeneration(expected) ==
            true;
    try {
      final result = await future;
      if (!mounted) return;
      if (!current() || !flow.isAuthorizationResultCurrent(result)) return;
      if (!result.opened) {
        showSnackBar(
          context,
          message:
              'Could not open the browser. Try again to resume the same authorization.',
        );
        return;
      }
      Navigator.pop(context);
    } catch (error) {
      if (mounted &&
          identical(_connectingOperation, operation) &&
          flow.isAuthorizationOperationCurrent(generation, credentials)) {
        setState(() => this.error = bankingErrorMessage(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final flow = ref.watch(connectBankFlowProvider);
    final aspsps = flow.aspsps;

    return Container(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppBar(title: const Text("Bank")),
          Expanded(
            child: SingleChildScrollView(
              controller: widget.scrollController,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (flow.authorizationOwner != null)
                    Padding(
                      padding: const EdgeInsets.all(Sizes.lg),
                      child: AuthorizationRecoveryControls(
                        onResumed: () {
                          if (mounted) Navigator.pop(context);
                        },
                      ),
                    ),
                  if (loading || flow.authorizing)
                    const Padding(
                      padding: EdgeInsets.all(Sizes.xl),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (flow.authorizationOwner != null)
                    const SizedBox.shrink()
                  else if (error != null)
                    Padding(
                      padding: const EdgeInsets.all(Sizes.xl),
                      child: Column(
                        children: [
                          Text(error!),
                          TextButton(
                            onPressed: _loadAspsps,
                            child: const Text('Try again'),
                          ),
                        ],
                      ),
                    )
                  else if (aspsps.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(Sizes.xl),
                      child: Text(
                        "No bank available in this country",
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    )
                  else
                    Container(
                      color: Theme.of(context).colorScheme.surface,
                      child: ListView.separated(
                        itemCount: aspsps.length,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        separatorBuilder: (context, index) =>
                            const Divider(height: 1, color: grey1),
                        itemBuilder: (context, i) {
                          final aspsp = aspsps[i];
                          return ListTile(
                            onTap: () => _connect(aspsp),
                            leading: _AspspLogo(
                              logo: aspsp.logoUri?.toString(),
                            ),
                            title: Text(aspsp.name),
                            subtitle: aspsp.isBeta
                                ? Text(
                                    "Beta",
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  )
                                : null,
                            trailing: Icon(
                              Icons.chevron_right,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Sizes.sm),
        ],
      ),
    );
  }
}

/// Bank logo, falling back to the generic bank icon whenever the ASPSP has no logo or it cannot be fetched.
class _AspspLogo extends StatelessWidget {
  const _AspspLogo({this.logo});

  final String? logo;

  @override
  Widget build(BuildContext context) {
    final fallback = RoundedIcon(
      icon: Icons.account_balance,
      backgroundColor: Theme.of(context).colorScheme.secondary,
      size: 30,
      padding: const EdgeInsets.all(Sizes.xs),
    );

    if (logo == null) return fallback;

    return ClipRRect(
      borderRadius: BorderRadius.circular(Sizes.borderRadiusSmall),
      child: Image.network(
        logo!,
        width: 38,
        height: 38,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => fallback,
      ),
    );
  }
}
