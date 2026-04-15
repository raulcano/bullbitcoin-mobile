enum DlcOptionType { call, put }

enum DlcOrderSide { buy, sell }

extension DlcOptionTypeX on DlcOptionType {
  String get value => this == DlcOptionType.call ? 'CALL' : 'PUT';
}

extension DlcOrderSideX on DlcOrderSide {
  String get value => this == DlcOrderSide.buy ? 'buy' : 'sell';
}

class DlcWalletAuth {
  final String walletId;
  final String walletToken;
  final DateTime? expiresAt;

  const DlcWalletAuth({
    required this.walletId,
    required this.walletToken,
    required this.expiresAt,
  });
}

class DlcOrderDraft {
  final String instrumentId;
  final DlcOrderSide side;
  final double quantity;
  final double price;
  final String fundingPubkeyHex;

  const DlcOrderDraft({
    required this.instrumentId,
    required this.side,
    required this.quantity,
    required this.price,
    required this.fundingPubkeyHex,
  });
}

class DlcOrderSummary {
  final String orderId;
  final String? dlcId;
  final String status;
  final bool pendingMatchAccept;
  final String? matchedOrderId;
  final String? matchedDlcId;

  const DlcOrderSummary({
    required this.orderId,
    required this.dlcId,
    required this.status,
    required this.pendingMatchAccept,
    required this.matchedOrderId,
    required this.matchedDlcId,
  });
}

class DlcSigningResult {
  final String fundingPubkeyHex;
  final List<String> cetAdaptorSignaturesHex;
  final String refundSignatureHex;
  final List<String> fundingSignaturesHex;

  const DlcSigningResult({
    required this.fundingPubkeyHex,
    required this.cetAdaptorSignaturesHex,
    required this.refundSignatureHex,
    required this.fundingSignaturesHex,
  });
}
