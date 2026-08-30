import 'enable_banking_exception.dart';

const String kEbAppCallbackUri = 'sossoldi://eb-callback';
const String kEbRedirectUri =
    'https://rip-comm.github.io/sossoldi/enablebanking/eb-callback.html';

const String _kLegacyHostedRedirectUri =
    'https://marianialessandro.com/sossoldi/eb-callback.html';

enum EnableBankingEnvironment {
  production,
  sandbox;

  static EnableBankingEnvironment fromJson(String value) =>
      EnableBankingEnvironment.values.firstWhere(
        (e) => e.name == value,
        orElse: () => EnableBankingEnvironment.production,
      );

  String toJson() => name;
}

// app_id and the private key are BYOC credentials; they live in
// EnableBankingCredentialsStore, not here.
class EnableBankingConfig {
  final String appId;
  final EnableBankingEnvironment environment;
  final String redirectUri;
  final String? defaultCountry;

  const EnableBankingConfig({
    required this.appId,
    this.environment = EnableBankingEnvironment.production,
    this.redirectUri = kEbRedirectUri,
    this.defaultCountry,
  });

  // Enable Banking serves the same host for both production and sandbox.
  String get baseUrl => 'https://api.enablebanking.com';

  static EnableBankingConfig fromJson(Map<String, dynamic> json) {
    try {
      final storedRedirectUri = json['redirect_uri'] as String?;
      return EnableBankingConfig(
        appId: json['app_id'] as String,
        environment: EnableBankingEnvironment.fromJson(
          json['environment'] as String? ?? 'production',
        ),
        redirectUri: storedRedirectUri == _kLegacyHostedRedirectUri
            ? kEbRedirectUri
            : storedRedirectUri ?? kEbRedirectUri,
        defaultCountry: json['default_country'] as String?,
      );
    } catch (e) {
      throw EnableBankingException(
        message: 'Malformed Enable Banking configuration: $e',
      );
    }
  }

  Map<String, dynamic> toJson() => {
    'app_id': appId,
    'environment': environment.toJson(),
    'redirect_uri': redirectUri,
    'default_country': defaultCountry,
  };
}
