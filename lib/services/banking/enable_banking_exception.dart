class EnableBankingException implements Exception {
  final int? statusCode;
  final String? error;
  final String? message;

  const EnableBankingException({this.statusCode, this.error, this.message});

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() =>
      'EnableBankingException(statusCode: $statusCode, error: $error, '
      'message: $message)';
}
