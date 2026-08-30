class EbAmount {
  final num amount;
  final String currency;

  const EbAmount({required this.amount, required this.currency});

  static EbAmount fromJson(Map<String, dynamic> json) => EbAmount(
    amount: num.parse(json['amount'] as String),
    currency: json['currency'] as String,
  );
}
