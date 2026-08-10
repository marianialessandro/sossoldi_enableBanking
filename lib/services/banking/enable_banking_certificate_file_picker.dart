import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart';

import '../../ui/snack_bars/snack_bar.dart';

/// Exports a freshly generated Enable Banking certificate to a file the
/// user picks a folder for, so they can upload it to the Enable Banking
/// control panel. Mirrors `CSVFilePicker.saveCSVFile`.
class EnableBankingCertificateFilePicker {
  static Future<String?> saveCertificateFile(
    String certificatePem,
    BuildContext context,
  ) async {
    try {
      final selectedDirectory = await FilePicker.platform.getDirectoryPath();
      if (selectedDirectory == null) {
        // User canceled the picker
        return null;
      }

      final filePath = join(selectedDirectory, 'enablebanking-certificate.pem');
      final file = await File(filePath).writeAsString(certificatePem);

      if (context.mounted) {
        showSnackBar(context, message: 'Certificate saved to: ${file.path}');
      }
      return file.path;
    } catch (e) {
      if (context.mounted) {
        showSnackBar(
          context,
          message:
              'Cannot save the certificate here, please create or select a '
              'folder in Downloads or Documents. Error: ${e.toString()}',
        );
      }
      return null;
    }
  }
}
