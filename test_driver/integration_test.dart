import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      final file = File('build/screenshots/$name.png')
        ..createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      return true;
    },
  );
}
