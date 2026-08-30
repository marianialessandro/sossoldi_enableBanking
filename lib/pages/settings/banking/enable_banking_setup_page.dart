import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../constants/style.dart';
import '../../../providers/banking_provider.dart';
import '../../../services/banking/enable_banking_auth.dart';
import '../../../services/banking/enable_banking_certificate_file_picker.dart';
import '../../../services/banking/enable_banking_config.dart';
import '../../../ui/device.dart';
import '../../../ui/snack_bars/snack_bar.dart';
import '../../../ui/widgets/alert_dialog.dart';
import '../../../ui/widgets/default_card.dart';
import '../../../ui/widgets/default_container.dart';
import 'widgets/certificate_ready_dialog.dart';
import 'widgets/confirm_clear_credentials_dialog.dart';
import 'widgets/confirm_regenerate_key_dialog.dart';

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
  final TextEditingController redirectUriController = TextEditingController(
    text: kEbRedirectUri,
  );
  bool useSandbox = false;
  bool hasStoredPrivateKey = false;
  String? generatedCertificatePem;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    appIdController.dispose();
    redirectUriController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final config = await ref.read(enableBankingSettingsProvider.future);
    if (!mounted) return;

    final storedKey = await ref
        .read(enableBankingCredentialsStoreProvider)
        .readPrivateKey();
    if (!mounted) return;

    setState(() {
      hasStoredPrivateKey = storedKey != null;
      if (config != null) {
        appIdController.text = config.appId;
        useSandbox = config.environment == EnableBankingEnvironment.sandbox;
        redirectUriController.text = config.redirectUri;
      }
    });
  }

  void _onGeneratePressed() {
    if (hasStoredPrivateKey) {
      showDialog(
        context: context,
        builder: (context) {
          return ConfirmRegenerateKeyDialog(
            onPressed: () {
              Navigator.of(context).pop();
              _generateKey();
            },
          );
        },
      );
      return;
    }
    _generateKey();
  }

  // Clears any previous config: the old app_id won't match the new key.
  Future<void> _generateKey() async {
    final hadCredentials =
        ref.read(enableBankingSettingsProvider).value != null;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: Sizes.lg),
            Expanded(
              child: Text(
                'Generating your key — this can take up to a minute…',
              ),
            ),
          ],
        ),
      ),
    );

    try {
      final material = await ref
          .read(enableBankingKeyGeneratorProvider)
          .generate();

      await ref
          .read(enableBankingCredentialsStoreProvider)
          .savePrivateKey(material.privateKeyPem);
      if (!mounted) return;

      if (hadCredentials) {
        await ref.read(enableBankingSettingsProvider.notifier).clearConfig();
        if (!mounted) return;
      }

      Navigator.of(context).pop(); // dismiss the "generating" dialog
      setState(() {
        appIdController.clear();
        hasStoredPrivateKey = true;
        generatedCertificatePem = material.certificatePem;
      });
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss the "generating" dialog
      showErrorDialog(context, 'Could not generate the key: ${e.toString()}');
    }
  }

  Future<void> _save() async {
    final appId = appIdController.text.trim();
    if (appId.isEmpty) {
      showErrorDialog(context, 'Enter your Enable Banking application ID');
      return;
    }

    final privateKeyPem =
        await ref
            .read(enableBankingCredentialsStoreProvider)
            .readPrivateKey() ??
        '';
    if (!mounted) return;
    if (privateKeyPem.isEmpty) {
      showErrorDialog(context, 'Generate a key and certificate first');
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

    final redirectUri = redirectUriController.text.trim();

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
            redirectUri: redirectUri.isEmpty ? kEbRedirectUri : redirectUri,
          ),
        );
    if (!mounted) return;

    if (ref.read(enableBankingSettingsProvider).hasError) {
      showErrorDialog(context, 'Could not save the credentials');
      return;
    }

    showSuccessDialog(context, 'Credentials saved');
  }

  Future<void> _clear() async {
    await ref.read(enableBankingSettingsProvider.notifier).clear();
    if (!mounted) return;

    appIdController.clear();
    setState(() {
      useSandbox = false;
      hasStoredPrivateKey = false;
      generatedCertificatePem = null;
      redirectUriController.text = kEbRedirectUri;
    });
    showSnackBar(context, message: 'Credentials cleared');
  }

  Future<void> _copyRedirectUri(BuildContext context) async {
    final text = redirectUriController.text.trim();
    await Clipboard.setData(
      ClipboardData(text: text.isEmpty ? kEbRedirectUri : text),
    );
    if (context.mounted) {
      showSnackBar(context, message: "Copied");
    }
  }

  Future<void> _copyGeneratedCertificate() async {
    final certificatePem = generatedCertificatePem;
    if (certificatePem == null) return;

    await Clipboard.setData(ClipboardData(text: certificatePem));
    if (mounted) {
      showSnackBar(context, message: 'Certificate copied');
    }
  }

  void _openGeneratedCertificate() {
    final certificatePem = generatedCertificatePem;
    if (certificatePem == null) return;

    showDialog(
      context: context,
      builder: (context) => CertificateReadyDialog(
        certificatePem: certificatePem,
        onSaveToFile: () =>
            EnableBankingCertificateFilePicker.saveCertificateFile(
              certificatePem,
              context,
            ),
      ),
    );
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
            if (hasCredentials) ...[
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
              Padding(
                padding: const EdgeInsets.only(bottom: Sizes.sm),
                child: DefaultCard(
                  onTap: () => Navigator.of(context).pushNamed('/connect-bank'),
                  child: Row(
                    children: [
                      Container(
                        decoration: const BoxDecoration(
                          color: blue5,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(Sizes.sm),
                        child: const Icon(
                          Icons.account_balance,
                          size: 30.0,
                          color: white,
                        ),
                      ),
                      const SizedBox(width: Sizes.md),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Linked banks",
                              style: Theme.of(context).textTheme.titleLarge!
                                  .copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                            ),
                            Text(
                              "Connect a bank and manage your connections",
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall!
                                  .copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (!hasCredentials && hasStoredPrivateKey)
              Padding(
                padding: const EdgeInsets.only(bottom: Sizes.sm),
                child: DefaultContainer(
                  child: Row(
                    spacing: Sizes.md,
                    children: [
                      const Icon(Icons.vpn_key, color: blue5),
                      Expanded(
                        child: Text(
                          "Key generated — upload the certificate from step "
                          "2, then enter your app_id in step 3 below",
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            DefaultContainer(
              child: Text(
                "Sossoldi talks to your bank through your own Enable "
                "Banking application. The credentials below never leave "
                "this device: they are stored encrypted and used to sign "
                "each request. Follow the steps below to set it up.",
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            _StepCard(
              step: 1,
              title: "Register your application",
              instructions:
                  "Create a free application on the Enable Banking portal. "
                  "You'll come back here to upload a certificate and enter "
                  "the app_id it gives you.",
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Sizes.sm),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => launchUrl(Uri.parse(_kEbApplicationsUrl)),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text("Open Enable Banking portal"),
                  ),
                ),
              ),
            ),
            _StepCard(
              step: 2,
              title: "Generate your key",
              instructions:
                  "Generate a secure key and certificate, then upload the "
                  "certificate to the application you just registered. "
                  "The private key stays protected on this device.",
              padding: const EdgeInsets.fromLTRB(
                Sizes.lg,
                Sizes.md,
                Sizes.lg,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Sizes.sm),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _onGeneratePressed,
                        icon: const Icon(Icons.auto_fix_high),
                        label: const Text("Generate new key & certificate"),
                      ),
                    ),
                  ),
                  if (generatedCertificatePem != null) ...[
                    const Divider(height: 1, color: grey2),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Sizes.md),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(Sizes.md),
                        decoration: BoxDecoration(
                          color: green.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(
                            Sizes.borderRadiusSmall,
                          ),
                          border: Border.all(
                            color: green.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: Sizes.sm,
                          children: [
                            Row(
                              spacing: Sizes.sm,
                              children: [
                                const Icon(Icons.check_circle, color: green),
                                Expanded(
                                  child: Text(
                                    'Certificate ready',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                              ],
                            ),
                            const Text(
                              'Copy it and upload it to your Enable Banking '
                              'application. You can also open it to inspect '
                              'or save it.',
                            ),
                            Wrap(
                              spacing: Sizes.sm,
                              runSpacing: Sizes.sm,
                              children: [
                                FilledButton.icon(
                                  onPressed: _copyGeneratedCertificate,
                                  icon: const Icon(Icons.copy),
                                  label: const Text('Copy certificate'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _openGeneratedCertificate,
                                  icon: const Icon(Icons.visibility),
                                  label: const Text('View certificate'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _StepCard(
              step: 3,
              title: "Enter your application ID",
              instructions:
                  "After uploading the certificate, Enable Banking shows "
                  "you an app_id. Paste it here.",
              child: TextField(
                controller: appIdController,
                decoration: const InputDecoration(
                  hintText: "Your Enable Banking app_id",
                ),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            _StepCard(
              step: 4,
              title: "Register the redirect URI",
              instructions:
                  "Copy this URI and register it as the redirect URL on "
                  "your application.",
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
                        child: TextField(
                          controller: redirectUriController,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy),
                        onPressed: () => _copyRedirectUri(context),
                      ),
                    ],
                  ),
                  Text(
                    "Register this exact HTTPS URL in Enable Banking. It "
                    "securely returns the authorization result to "
                    "$kEbAppCallbackUri — see the setup guide.",
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            _StepCard(
              step: 5,
              title: "Choose your environment",
              instructions:
                  "Use sandbox to test with Enable Banking's mock banks "
                  "before going live.",
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

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.step,
    required this.title,
    required this.child,
    this.instructions,
    this.padding = const EdgeInsets.fromLTRB(Sizes.lg, Sizes.md, Sizes.lg, 0),
  });

  final int step;
  final String title;
  final String? instructions;
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
          Row(
            spacing: Sizes.sm,
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context).colorScheme.secondary,
                ),
                child: Text(
                  '$step',
                  style: const TextStyle(
                    color: white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ],
          ),
          if (instructions != null)
            Padding(
              padding: const EdgeInsets.only(
                top: Sizes.xs,
                left: 32,
                bottom: Sizes.xs,
              ),
              child: Text(
                instructions!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          child,
        ],
      ),
    );
  }
}
