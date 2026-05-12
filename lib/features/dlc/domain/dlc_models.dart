enum DlcOptionType { call, put }

enum DlcOrderSide { buy, sell }

extension DlcOptionTypeX on DlcOptionType {
  String get value => this == DlcOptionType.call ? 'CALL' : 'PUT';
}

extension DlcOrderSideX on DlcOrderSide {
  String get value => this == DlcOrderSide.buy ? 'buy' : 'sell';
}

class DlcWalletAuth {
  final String walletOriginId;
  final String walletLabel;
  final String walletXpub;
  final String walletId;
  final String walletToken;
  final DateTime? expiresAt;

  const DlcWalletAuth({
    required this.walletOriginId,
    required this.walletLabel,
    required this.walletXpub,
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
  final bool? isMaker;
  final String? matchRole;
  final bool? signRequired;
  final String? dlcStatus;
  final String? settlementType;
  final String? confirmationStatus;
  final String? instrumentId;
  final String? side;
  final double? quantity;
  final double? price;
  final String? lastErrorReason;
  final String? lastErrorMessage;
  final String? oracleOutcomeValue;
  final String? fundingTxid;
  final String? closingTxid;
  final String? refundTxid;

  const DlcOrderSummary({
    required this.orderId,
    required this.dlcId,
    required this.status,
    required this.pendingMatchAccept,
    required this.matchedOrderId,
    required this.matchedDlcId,
    required this.isMaker,
    required this.matchRole,
    required this.signRequired,
    required this.dlcStatus,
    required this.settlementType,
    required this.confirmationStatus,
    required this.instrumentId,
    required this.side,
    required this.quantity,
    required this.price,
    required this.lastErrorReason,
    required this.lastErrorMessage,
    required this.oracleOutcomeValue,
    required this.fundingTxid,
    required this.closingTxid,
    required this.refundTxid,
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

class DlcWalletOption {
  final String walletOriginId;
  final String label;
  final String xpub;

  const DlcWalletOption({
    required this.walletOriginId,
    required this.label,
    required this.xpub,
  });
}

class DlcExpiredWalletInfo {
  final String walletId;
  final String xpub;

  const DlcExpiredWalletInfo({required this.walletId, required this.xpub});
}
