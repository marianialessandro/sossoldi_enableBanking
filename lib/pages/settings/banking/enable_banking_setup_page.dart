import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../constants/style.dart';
import '../../../providers/banking_provider.dart';
import '../../../services/banking/enable_banking_auth.dart';
import '../../../services/banking/enable_banking_config.dart';
import '../../../services/banking/pem_file_picker.dart';
import '../../../ui/device.dart';
import '../../../ui/snack_bars/snack_bar.dart';
import '../../../ui/widgets/alert_dialog.dart';
import '../../../ui/widgets/default_container.dart';
import 'widgets/confirm_clear_credentials_dialog.dart';

/// Where the user registers their own Enable Banking application (BYOC).
const _kEbApplicationsUrl = 'https://enablebanking.com/cp/applications';

class EnableBankingSetupPage extends ConsumerStatefulWidget {
  const EnableBankingSetupPage({super.key});

  @override
  ConsumerState<EnableBankingSetupPage> createState() =>
      _EnableBankingSetupPageState();
}

class _EnableBankingSetupPageState
    extends ConsumerState<EnableBankingSetupPage> {
  final TextEditingController appIdController = TextEditingController();
  final TextEditingController pemController = TextEditingController();
  bool useSandbox = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    appIdController.dispose();
    pemController.dispose();
    super.dispose();
  }

  /// The saved configuration comes from secure storage, so the fields are
  /// filled in once it lands. The private key is never read back into the
  /// form: an empty field means "keep the key already stored".
  Future<void> _loadConfig() async {
    final config = await ref.read(enableBankingSettingsProvider.future);
    if (!mounted || config == null) return;

    setState(() {
      appIdController.text = config.appId;
      useSandbox = config.environment == EnableBankingEnvironment.sandbox;
    });
  }

  Future<void> _importPrivateKey() async {
    final file = await PemFilePicker.pickPemFile(context);
    if (file == null) return;

    try {
      final content = await file.readAsString();
      if (!mounted) return;
      setState(() => pemController.text = content.trim());
    } catch (e) {
      if (!mounted) return;
      showSnackBar(context, message: 'Could not read the file: $e');
    }
  }

  Future<void> _save() async {
    final appId = appIdController.text.trim();
    if (appId.isEmpty) {
      showErrorDialog(context, 'Enter your Enable Banking application ID');
      return;
    }

    var privateKeyPem = pemController.text.trim();
    if (privateKeyPem.isEmpty) {
      privateKeyPem =
          await ref
              .read(enableBankingCredentialsStoreProvider)
              .readPrivateKey() ??
          '';
      if (!mounted) return;
    }
    if (privateKeyPem.isEmpty) {
      showErrorDialog(context, 'Enter or import your private key');
      return;
    }

    try {
      // Signing a throwaway token is the cheapest way to reject an
      // unparsable key before it ever reaches the API.
      ref
          .read(enableBankingAuthProvider)
          .buildJwt(appId: appId, privateKeyPem: privateKeyPem);
    } on EnableBankingAuthException catch (e) {
      showErrorDialog(context, e.message);
      return;
    }

    await ref
        .read(enableBankingSettingsProvider.notifier)
        .save(
          appId: appId,
          privateKeyPem: privateKeyPem,
          config: EnableBankingConfig(
            appId: appId,
            environment: useSandbox
                ? EnableBankingEnvironment.sandbox
                : EnableBankingEnvironment.production,
          ),
        );
    if (!mounted) return;

    if (ref.read(enableBankingSettingsProvider).hasError) {
      showErrorDialog(context, 'Could not save the credentials');
      return;
    }

    pemController.clear();
    showSuccessDialog(context, 'Credentials saved');
  }

  Future<void> _clear() async {
    await ref.read(enableBankingSettingsProvider.notifier).clear();
    if (!mounted) return;

    appIdController.clear();
    pemController.clear();
    setState(() => useSandbox = false);
    showSnackBar(context, message: 'Credentials cleared');
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(enableBankingSettingsProvider).value;
    final hasCredentials = config != null;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Bank sync'),
      ),
      persistentFooterDecoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.15),
            blurRadius: 5.0,
            offset: const Offset(0, -1.0),
          ),
        ],
      ),
      persistentFooterButtons: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Sizes.sm,
            Sizes.xs,
            Sizes.sm,
            Sizes.sm,
          ),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              boxShadow: [defaultShadow],
              borderRadius: BorderRadius.circular(Sizes.borderRadius),
            ),
            child: ElevatedButton(
              onPressed: _save,
              child: const Text("SAVE CREDENTIALS"),
            ),
          ),
        ),
      ],
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: Sizes.sm),
        physics: const BouncingScrollPhysics(),
        child: Column(
          children: [
            if (hasCredentials)
              Padding(
                padding: const EdgeInsets.only(bottom: Sizes.sm),
                child: DefaultContainer(
                  child: Row(
                    spacing: Sizes.md,
                    children: [
                      const Icon(Icons.check_circle, color: green),
                      Expanded(
                        child: Text(
                          "Credentials configured",
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            DefaultContainer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Sossoldi talks to your bank through your own Enable "
                    "Banking application. The credentials below never leave "
                    "this device: they are stored encrypted and used to sign "
                    "each request.",
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  TextButton(
                    onPressed: () => launchUrl(Uri.parse(_kEbApplicationsUrl)),
                    child: Text(
                      "Register your application",
                      style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _FieldCard(
              label: "APPLICATION ID",
              child: TextField(
                controller: appIdController,
                decoration: const InputDecoration(
                  hintText: "Your Enable Banking app_id",
                ),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            _FieldCard(
              label: "PRIVATE KEY (PEM)",
              padding: const EdgeInsets.fromLTRB(
                Sizes.lg,
                Sizes.md,
                Sizes.lg,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: pemController,
                    maxLines: 6,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(
                      hintText: hasCredentials
                          ? "•••• configured"
                          : "-----BEGIN PRIVATE KEY-----",
                    ),
                    // A key blob is unreadable at the titleLarge size used by
                    // the other fields.
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const Divider(height: 1, color: grey2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "Import from file",
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      IconButton(
                        icon: const Icon(Icons.upload_file),
                        onPressed: _importPrivateKey,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _FieldCard(
              label: "ENVIRONMENT",
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Sizes.md),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "Use sandbox",
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    Switch.adaptive(
                      value: useSandbox,
                      onChanged: (value) => setState(() => useSandbox = value),
                    ),
                  ],
                ),
              ),
            ),
            _FieldCard(
              label: "REDIRECT URI",
              padding: const EdgeInsets.fromLTRB(
                Sizes.lg,
                Sizes.md,
                Sizes.lg,
                Sizes.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          kEbRedirectUri,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy),
                        onPressed: () async {
                          await Clipboard.setData(
                            const ClipboardData(text: kEbRedirectUri),
                          );
                          if (context.mounted) {
                            showSnackBar(context, message: "Copied");
                          }
                        },
                      ),
                    ],
                  ),
                  Text(
                    "Register this URI as redirect URL in your Enable "
                    "Banking application",
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (hasCredentials)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Sizes.lg),
                child: TextButton.icon(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) {
                        return ConfirmClearCredentialsDialog(
                          onPressed: () {
                            Navigator.of(context).pop();
                            _clear();
                          },
                        );
                      },
                    );
                  },
                  style: TextButton.styleFrom(
                    side: const BorderSide(color: red, width: 1),
                  ),
                  icon: const Icon(Icons.delete_outlined, color: red),
                  label: Text(
                    "Clear credentials",
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge!.copyWith(color: red),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Form card of the page: uppercase label on top of the field, on a surface
/// coloured container (same shape as the account form cards).
class _FieldCard extends StatelessWidget {
  const _FieldCard({
    required this.label,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(Sizes.lg, Sizes.md, Sizes.lg, 0),
  });

  final String label;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(
        horizontal: Sizes.lg,
        vertical: Sizes.sm,
      ),
      padding: padding,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(Sizes.borderRadiusSmall),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          child,
        ],
      ),
    );
  }
}
