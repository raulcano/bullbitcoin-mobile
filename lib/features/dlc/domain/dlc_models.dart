import 'dlc_order_in_flight.dart';

export 'dlc_order_in_flight.dart' show DlcOrderInFlightPhase;

enum DlcOptionType { call, put }

enum DlcOrderSide { buy, sell }

/// Aggregated and full depth for one strike on the coordinator orderbook.
class DlcStrikeOrderbookSnapshot {
  final double strikePrice;
  final List<Map<String, dynamic>> bids;
  final List<Map<String, dynamic>> asks;
  final int? lowestAskPremiumSats;
  final int? highestBidPremiumSats;

  const DlcStrikeOrderbookSnapshot({
    required this.strikePrice,
    required this.bids,
    required this.asks,
    required this.lowestAskPremiumSats,
    required this.highestBidPremiumSats,
  });
}

extension DlcOptionTypeX on DlcOptionType {
  String get value => this == DlcOptionType.call ? 'CALL' : 'PUT';
}

extension DlcOrderSideX on DlcOrderSide {
  String get value => this == DlcOrderSide.buy ? 'buy' : 'sell';
}

class DlcWalletSyncResult {
  final Map<String, dynamic> raw;

  const DlcWalletSyncResult(this.raw);

  factory DlcWalletSyncResult.fromJson(Map<String, dynamic> json) {
    return DlcWalletSyncResult(Map<String, dynamic>.from(json));
  }

  int? get totalBalanceSat => (raw['total_balance'] as num?)?.toInt();

  int? get availableBalanceSat => (raw['available_balance'] as num?)?.toInt();

  int? get reservedBalanceSat => (raw['reserved_balance'] as num?)?.toInt();

  String? get warning => raw['warning'] as String?;

  String? get utxoSyncError => raw['utxo_sync_error'] as String?;

  List<Map<String, dynamic>> get cancelledOrders =>
      (raw['cancelled_orders'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);

  List<Map<String, dynamic>> get rejectedUtxos =>
      (raw['rejected_utxos'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);

  bool get hasCancelledOrders => cancelledOrders.isNotEmpty;
}

class DlcCreateOrderResult {
  final DlcOrderSummary order;
  final DlcWalletSyncResult syncBefore;

  const DlcCreateOrderResult({required this.order, required this.syncBefore});
}

class DlcCancelOrderResult {
  final DlcOrderSummary? order;
  final DlcWalletSyncResult? syncAfter;
  final bool removedBecauseNotFoundOnCoordinator;

  const DlcCancelOrderResult({
    required this.order,
    this.syncAfter,
    this.removedBecauseNotFoundOnCoordinator = false,
  });

  const DlcCancelOrderResult.staleRemovedLocally()
    : order = null,
      syncAfter = null,
      removedBecauseNotFoundOnCoordinator = true;
}

enum DlcNegotiationActionKind { takerAccept, makerSign }

class DlcNegotiationAction {
  final DlcNegotiationActionKind kind;
  final String orderId;
  final String? dlcId;

  const DlcNegotiationAction({
    required this.kind,
    required this.orderId,
    this.dlcId,
  });
}

class DlcNegotiationPassResult {
  final List<DlcNegotiationAction> actions;
  final List<String> errors;
  final List<DlcOrderSummary> orders;

  const DlcNegotiationPassResult({
    required this.actions,
    required this.errors,
    required this.orders,
  });

  factory DlcNegotiationPassResult.skipped() =>
      const DlcNegotiationPassResult(actions: [], errors: [], orders: []);

  bool get didWork => actions.isNotEmpty;
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

  /// Premium per contract in satoshis (Create order form).
  final double price;
  final double? strikePrice;
  final String fundingPubkeyHex;

  const DlcOrderDraft({
    required this.instrumentId,
    required this.side,
    required this.quantity,
    required this.price,
    required this.strikePrice,
    required this.fundingPubkeyHex,
  });
}

class DlcFundingPubkey {
  final String pubkeyHex;
  final String derivationPath;

  const DlcFundingPubkey({
    required this.pubkeyHex,
    required this.derivationPath,
  });
}

class DlcOrderSummary {
  final String orderId;
  final String? dlcId;
  final String status;
  final bool pendingMatchAccept;
  final DlcOrderInFlightPhase? inFlightPhase;
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
  final DateTime? createdAt;
  final double? sideCollateralSat;
  final double? partnerFeeSat;
  final double? networkFeeSat;
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
    this.inFlightPhase,
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
    required this.createdAt,
    required this.sideCollateralSat,
    required this.partnerFeeSat,
    required this.networkFeeSat,
    required this.lastErrorReason,
    required this.lastErrorMessage,
    required this.oracleOutcomeValue,
    required this.fundingTxid,
    required this.closingTxid,
    required this.refundTxid,
  });

  DlcOrderSummary copyWith({
    String? orderId,
    String? dlcId,
    String? status,
    bool? pendingMatchAccept,
    DlcOrderInFlightPhase? inFlightPhase,
    bool clearInFlightPhase = false,
    String? matchedOrderId,
    String? matchedDlcId,
    bool? isMaker,
    String? matchRole,
    bool? signRequired,
    String? dlcStatus,
    String? settlementType,
    String? confirmationStatus,
    String? instrumentId,
    String? side,
    double? quantity,
    double? price,
    DateTime? createdAt,
    double? sideCollateralSat,
    double? partnerFeeSat,
    double? networkFeeSat,
    String? lastErrorReason,
    String? lastErrorMessage,
    String? oracleOutcomeValue,
    String? fundingTxid,
    String? closingTxid,
    String? refundTxid,
  }) {
    return DlcOrderSummary(
      orderId: orderId ?? this.orderId,
      dlcId: dlcId ?? this.dlcId,
      status: status ?? this.status,
      pendingMatchAccept: pendingMatchAccept ?? this.pendingMatchAccept,
      inFlightPhase: clearInFlightPhase
          ? null
          : (inFlightPhase ?? this.inFlightPhase),
      matchedOrderId: matchedOrderId ?? this.matchedOrderId,
      matchedDlcId: matchedDlcId ?? this.matchedDlcId,
      isMaker: isMaker ?? this.isMaker,
      matchRole: matchRole ?? this.matchRole,
      signRequired: signRequired ?? this.signRequired,
      dlcStatus: dlcStatus ?? this.dlcStatus,
      settlementType: settlementType ?? this.settlementType,
      confirmationStatus: confirmationStatus ?? this.confirmationStatus,
      instrumentId: instrumentId ?? this.instrumentId,
      side: side ?? this.side,
      quantity: quantity ?? this.quantity,
      price: price ?? this.price,
      createdAt: createdAt ?? this.createdAt,
      sideCollateralSat: sideCollateralSat ?? this.sideCollateralSat,
      partnerFeeSat: partnerFeeSat ?? this.partnerFeeSat,
      networkFeeSat: networkFeeSat ?? this.networkFeeSat,
      lastErrorReason: lastErrorReason ?? this.lastErrorReason,
      lastErrorMessage: lastErrorMessage ?? this.lastErrorMessage,
      oracleOutcomeValue: oracleOutcomeValue ?? this.oracleOutcomeValue,
      fundingTxid: fundingTxid ?? this.fundingTxid,
      closingTxid: closingTxid ?? this.closingTxid,
      refundTxid: refundTxid ?? this.refundTxid,
    );
  }
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
