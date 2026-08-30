import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../constants/style.dart';
import '../../../providers/banking_provider.dart';
import '../../../services/banking/enable_banking_auth.dart';
import '../../../services/banking/enable_banking_exception.dart';
import '../../../services/banking/models/aspsp.dart';
import '../../../ui/device.dart';
import '../../../ui/snack_bars/snack_bar.dart';
import '../../../ui/widgets/rounded_icon.dart';

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
  bool connecting = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadAspsps();
  }

  Future<void> _loadAspsps() async {
    try {
      await ref
          .read(connectBankFlowProvider.notifier)
          .loadAspsps(widget.country);
    } on EnableBankingException catch (e) {
      error = e.message ?? 'Could not load the banks';
    } on EnableBankingAuthException catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Could not load the banks';
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _connect(Aspsp aspsp) async {
    setState(() => connecting = true);
    try {
      final url = await ref
          .read(connectBankFlowProvider.notifier)
          .startConnection(aspsp);
      if (!mounted) return;

      Navigator.pop(context);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } on EnableBankingException catch (e) {
      if (!mounted) return;
      showSnackBar(context, message: e.message ?? 'Authorization failed');
    } on EnableBankingAuthException catch (e) {
      if (!mounted) return;
      showSnackBar(context, message: e.message);
    } catch (e) {
      if (!mounted) return;
      showSnackBar(context, message: 'Could not connect to the bank');
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final aspsps = ref.watch(connectBankFlowProvider).aspsps;

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
                  if (loading || connecting)
                    const Padding(
                      padding: EdgeInsets.all(Sizes.xl),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (error != null)
                    Padding(
                      padding: const EdgeInsets.all(Sizes.xl),
                      child: Text('Error: $error'),
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
                            leading: _AspspLogo(logo: aspsp.logo),
                            title: Text(aspsp.name),
                            subtitle: aspsp.beta
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
