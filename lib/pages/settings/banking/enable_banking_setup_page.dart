import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../constants/style.dart';
import '../../../providers/banking_provider.dart';
import '../../../services/banking/enable_banking_auth.dart';
import '../../../services/banking/enable_banking_certificate_file_picker.dart';
import '../../../services/banking/enable_banking_config.dart';
import '../../../services/banking/pem_file_picker.dart';
import '../../../ui/device.dart';
import '../../../ui/snack_bars/snack_bar.dart';
import '../../../ui/widgets/alert_dialog.dart';
import '../../../ui/widgets/default_card.dart';
import '../../../ui/widgets/default_container.dart';
import 'widgets/confirm_clear_credentials_dialog.dart';
import 'widgets/confirm_regenerate_key_dialog.dart';

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
  final TextEditingController redirectUriController = TextEditingController(
    text: kEbRedirectUri,
  );
  bool useSandbox = false;
  bool hasStoredPrivateKey = false;
  bool pemVisible = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    appIdController.dispose();
    pemController.dispose();
    redirectUriController.dispose();
    super.dispose();
  }

  /// The saved configuration comes from secure storage, so the fields are
  /// filled in once it lands. The private key is never read back into the
  /// form: an empty field means "keep the key already stored".
  Future<void> _loadConfig() async {
    final config = await ref.read(enableBankingSettingsProvider.future);
    if (!mounted) return;

    if (config != null) {
      setState(() {
        appIdController.text = config.appId;
        useSandbox = config.environment == EnableBankingEnvironment.sandbox;
        redirectUriController.text = config.redirectUri;
      });
      return;
    }

    // No app_id yet, but a key may already have been generated in-app while
    // waiting for the certificate to be registered on Enable Banking.
    final storedKey = await ref
        .read(enableBankingCredentialsStoreProvider)
        .readPrivateKey();
    if (!mounted) return;
    setState(() => hasStoredPrivateKey = storedKey != null);
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

  /// Generates a fresh RSA key pair + self-signed certificate on-device,
  /// stores the private key immediately (it's never shown/exported), and
  /// exports the certificate for the user to upload to their Enable
  /// Banking application.
  ///
  /// If credentials were already saved (app_id linked to the previous
  /// certificate), that config is cleared: the old app_id no longer matches
  /// the new key, so keeping it around would leave the app silently signing
  /// requests Enable Banking rejects. The user must re-enter the app_id and
  /// save again once the new certificate is uploaded. The private key just
  /// written above is left untouched by this — only the old app_id/config
  /// are cleared.
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
        pemController.clear();
        hasStoredPrivateKey = true;
      });

      await EnableBankingCertificateFilePicker.saveCertificateFile(
        material.certificatePem,
        context,
      );
      if (!mounted) return;

      showSuccessDialog(
        context,
        'Key generated. Upload the certificate you just saved to your '
        'Enable Banking application, then paste the app_id below and save.',
      );
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

    pemController.clear();
    showSuccessDialog(context, 'Credentials saved');
  }

  Future<void> _clear() async {
    await ref.read(enableBankingSettingsProvider.notifier).clear();
    if (!mounted) return;

    appIdController.clear();
    pemController.clear();
    setState(() {
      useSandbox = false;
      redirectUriController.text = kEbRedirectUri;
    });
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
                          "Key generated — upload the certificate to Enable "
                          "Banking, then enter your app_id below",
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
                    // Obscured fields can't be multiline, so the key only
                    // wraps into full multi-line PEM once explicitly
                    // revealed; hidden by default it's a single obscured
                    // line, matching "saved encrypted" from the copy above.
                    obscureText: !pemVisible,
                    maxLines: pemVisible ? 6 : 1,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(
                      hintText: hasCredentials
                          ? "•••• configured"
                          : "-----BEGIN PRIVATE KEY-----",
                      suffixIcon: IconButton(
                        icon: Icon(
                          pemVisible ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () =>
                            setState(() => pemVisible = !pemVisible),
                      ),
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
                  const Divider(height: 1, color: grey2),
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
                        child: TextField(
                          controller: redirectUriController,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy),
                        onPressed: () async {
                          final text = redirectUriController.text.trim();
                          await Clipboard.setData(
                            ClipboardData(
                              text: text.isEmpty ? kEbRedirectUri : text,
                            ),
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
                    "Banking application. If it rejects the app's own "
                    "$kEbRedirectUri scheme (common in production), enter "
                    "an HTTPS URL you control that bounces back to it "
                    "instead — see the setup guide.",
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
