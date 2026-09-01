import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/services/banking/enable_banking_platform_support.dart';

void main() {
  test('feature-gates platforms without a reliable callback registration', () {
    expect(
      EnableBankingPlatformSupport.supportsCallback(
        platform: TargetPlatform.android,
        isWeb: false,
      ),
      isTrue,
    );
    expect(
      EnableBankingPlatformSupport.supportsCallback(
        platform: TargetPlatform.iOS,
        isWeb: false,
      ),
      isTrue,
    );
    expect(
      EnableBankingPlatformSupport.supportsCallback(
        platform: TargetPlatform.macOS,
        isWeb: false,
      ),
      isTrue,
    );
    expect(
      EnableBankingPlatformSupport.supportsCallback(
        platform: TargetPlatform.windows,
        isWeb: false,
      ),
      isFalse,
    );
    expect(
      EnableBankingPlatformSupport.supportsCallback(
        platform: TargetPlatform.linux,
        isWeb: false,
      ),
      isFalse,
    );
    expect(
      EnableBankingPlatformSupport.supportsCallback(
        platform: TargetPlatform.android,
        isWeb: true,
      ),
      isFalse,
    );
  });
}
