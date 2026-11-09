import 'package:sqflite/sqflite.dart';

import '../../model/category_transaction.dart';
import '../../model/recurring_transaction.dart';
import '../../model/transaction.dart';
import '../../model/bank_connection.dart';
import '../banking/lifecycle/banking_backup_policy.dart';

/// Validates the full file before any existing table can be overwritten.
class CsvImportValidator {
  const CsvImportValidator._();

  static Future<Map<List<dynamic>, Map<String, Object?>>> validate(
    DatabaseExecutor database,
    List<String> headers,
    List<List<dynamic>> rows,
    int tableNameIndex,
  ) async {
    if (headers.toSet().length != headers.length ||
        headers.any((name) => name.isEmpty)) {
      throw const FormatException('CSV headers must be nonempty and unique');
    }
    final tables = (await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
    )).map((row) => row['name'] as String).toSet();
    final schemas = <String, List<Map<String, Object?>>>{};
    final validated = <List<dynamic>, Map<String, Object?>>{};
    for (var index = 0; index < rows.length; index++) {
      final source = rows[index];
      final number = index + 2;
      if (source.length != headers.length) {
        throw FormatException('CSV row $number has an invalid column count');
      }
      final table = source[tableNameIndex].toString();
      if (!tables.contains(table)) {
        throw FormatException('CSV row $number names an unsupported table');
      }
      final schema = schemas[table] ??= await database.rawQuery(
        'PRAGMA table_info("${table.replaceAll('"', '""')}")',
      );
      final columns = {
        for (final column in schema) column['name'] as String: column,
      };
      final row = <String, Object?>{};
      for (var columnIndex = 0; columnIndex < headers.length; columnIndex++) {
        if (columnIndex == tableNameIndex) continue;
        final value = source[columnIndex];
        if (value == '' || value == null) continue;
        final field = headers[columnIndex];
        final column = columns[field];
        if (column == null) _invalid(number, table, field);
        final type = (column['type'] as String).toUpperCase();
        final semanticText =
            field == 'type' &&
            (table == transactionTable ||
                table == recurringTransactionTable ||
                table == categoryTransactionTable);
        if (semanticText) {
          row[field] = value.toString();
        } else if (type.contains('INT')) {
          final integer = int.tryParse(value.toString());
          if (integer != null) {
            row[field] = integer;
          } else {
            final numberValue = num.tryParse(value.toString());
            if (numberValue == null ||
                !numberValue.isFinite ||
                numberValue.abs() > 9007199254740991 ||
                numberValue != numberValue.truncateToDouble()) {
              _invalid(number, table, field);
            }
            row[field] = numberValue.toInt();
          }
        } else if (type.contains('REAL') ||
            type.contains('NUM') ||
            type.contains('DOUBLE') ||
            type.contains('FLOAT')) {
          final numberValue = num.tryParse(value.toString());
          if (numberValue == null || !numberValue.isFinite) {
            _invalid(number, table, field);
          }
          row[field] = numberValue;
        } else if (type.contains('TEXT') || type.contains('CHAR')) {
          row[field] = value.toString();
        } else {
          row[field] = value;
        }
      }
      final sanitized = BankingBackupPolicy.sanitizeForRestore(table, row);
      for (final column in schema) {
        final field = column['name'] as String;
        if (column['notnull'] == 1 &&
            column['dflt_value'] == null &&
            sanitized[field] == null) {
          _invalid(number, table, field);
        }
      }
      for (final field in [
        'date',
        'fromDate',
        'toDate',
        'lastInsertion',
        'createdAt',
        'updatedAt',
        'deletedAt',
        'lastSyncAt',
        'validUntil',
        'pendingValidUntil',
      ]) {
        final value = sanitized[field];
        if (value != null && (value is! String || !_validDate(value))) {
          _invalid(number, table, field);
        }
      }
      for (final field in [
        'active',
        'countNetWorth',
        'mainAccount',
        'recurring',
        'mainCurrency',
      ]) {
        final value = sanitized[field];
        if (value != null && value != 0 && value != 1) {
          _invalid(number, table, field);
        }
      }
      if (table == transactionTable) {
        if (sanitized['date'] == null) _invalid(number, table, 'date');
        _enumValue(
          number,
          table,
          'type',
          () => TransactionType.fromJson(sanitized['type'] as String),
        );
      } else if (table == recurringTransactionTable) {
        _enumValue(
          number,
          table,
          'type',
          () => TransactionType.fromJson(sanitized['type'] as String),
        );
        _enumValue(
          number,
          table,
          'recurrency',
          () => Recurrence.fromJson(sanitized['recurrency'] as String),
        );
      } else if (table == categoryTransactionTable) {
        _enumValue(
          number,
          table,
          'type',
          () => CategoryTransactionType.fromJson(sanitized['type'] as String),
        );
      } else if (table == bankConnectionTable) {
        _enumValue(
          number,
          table,
          'status',
          () => BankConnectionStatus.fromJson(sanitized['status'] as String),
        );
      }
      validated[source] = sanitized;
    }
    return validated;
  }

  static bool _validDate(String value) {
    if (DateTime.tryParse(value) == null) return false;
    final date = RegExp(r'^([+-]?\d{4,6})-?(\d{2})-?(\d{2})').firstMatch(value);
    if (date == null) return false;
    final year = int.parse(date[1]!);
    final month = int.parse(date[2]!);
    final day = int.parse(date[3]!);
    if (month < 1 || month > 12 || day < 1) return false;
    try {
      if (day > DateTime.utc(year, month + 1, 0).day) return false;
    } catch (_) {
      return false;
    }
    final time = RegExp(
      r'^[Tt ](\d{2})(?::?(\d{2}))?(?::?(\d{2}))?',
    ).firstMatch(value.substring(date.end));
    if (time != null &&
        (int.parse(time[1]!) > 23 ||
            int.parse(time[2] ?? '0') > 59 ||
            int.parse(time[3] ?? '0') > 59)) {
      return false;
    }
    final offset = RegExp(
      r'[+-](\d{2})(?::?(\d{2}))?$',
    ).firstMatch(value.substring(date.end));
    if (offset != null &&
        (int.parse(offset[1]!) > 23 || int.parse(offset[2] ?? '0') > 59)) {
      return false;
    }
    return true;
  }

  static void _enumValue(
    int number,
    String table,
    String field,
    Object? Function() read,
  ) {
    try {
      read();
    } catch (_) {
      _invalid(number, table, field);
    }
  }

  static Never _invalid(int number, String table, String field) {
    throw FormatException('Invalid CSV row $number in $table: $field');
  }
}
