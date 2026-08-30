import 'package:basic_utils/basic_utils.dart';
import 'package:flutter/foundation.dart';

const kEnableBankingKeySize = 4096;
const kEnableBankingCertificateValidityDays = 730;

class EnableBankingKeyMaterial {
  final String privateKeyPem;
  final String certificatePem;

  const EnableBankingKeyMaterial({
    required this.privateKeyPem,
    required this.certificatePem,
  });
}

// Top-level (not a method) so it can run on a background isolate via
// compute: RSA generation at this key size is CPU-heavy.
EnableBankingKeyMaterial generateEnableBankingKeyMaterial(int keySize) {
  final pair = CryptoUtils.generateRSAKeyPair(keySize: keySize);
  final privateKey = pair.privateKey as RSAPrivateKey;
  final publicKey = pair.publicKey as RSAPublicKey;

  final csrPem = X509Utils.generateRsaCsrPem(
    {'CN': 'Sossoldi Enable Banking'},
    privateKey,
    publicKey,
  );
  final certificatePem = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csrPem,
    kEnableBankingCertificateValidityDays,
  );

  return EnableBankingKeyMaterial(
    privateKeyPem: CryptoUtils.encodeRSAPrivateKeyToPem(privateKey),
    certificatePem: certificatePem,
  );
}

// Wraps generateEnableBankingKeyMaterial in a class so tests can fake it
// instead of running real RSA generation.
class EnableBankingKeyGenerator {
  const EnableBankingKeyGenerator();

  Future<EnableBankingKeyMaterial> generate({
    int keySize = kEnableBankingKeySize,
  }) => compute(generateEnableBankingKeyMaterial, keySize);
}
