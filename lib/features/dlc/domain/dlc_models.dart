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

/// One match attempt on an order. Each call to `POST /orders/{id}/accept-match`
/// (taker) or each match the resting maker discovers produces an execution.
///
/// Failed and expired executions stay in [DlcOrderSummary.executions] so the
/// order can show its full match history. Use [DlcOrderSummary.latestExecution]
/// for current display.
class DlcOrderExecution {
  final String tradeId;
  final String dlcId;
  final String role; // 'maker' | 'taker'
  final String? counterpartyOrderId;
  final double? quantity;
  final double? price;

  /// pending_accept | executed | failed | expired
  final String status;

  final DateTime? reservedAt;
  final DateTime? executedAt;

  /// Optional canonical DLC status (e.g. `accepted`, `signed`,
  /// `funding_broadcasted`) when the coordinator returns it inline on the
  /// execution. Falls back to [DlcOrderSummary.dlcStatus] for current display.
  final String? dlcStatus;

  /// Optional canonical funding txid; matches [DlcOrderSummary.fundingTxid] for
  /// the latest execution.
  final String? fundingTxid;

  /// Optional canonical settlement / refund txids.
  final String? closingTxid;
  final String? refundTxid;

  /// Optional last error reason / message recorded against the execution
  /// (visible after `failed` or `expired`).
  final String? lastErrorReason;
  final String? lastErrorMessage;

  const DlcOrderExecution({
    required this.tradeId,
    required this.dlcId,
    required this.role,
    this.counterpartyOrderId,
    this.quantity,
    this.price,
    required this.status,
    this.reservedAt,
    this.executedAt,
    this.dlcStatus,
    this.fundingTxid,
    this.closingTxid,
    this.refundTxid,
    this.lastErrorReason,
    this.lastErrorMessage,
  });

  bool get isMaker => role.toLowerCase() == 'maker';
  bool get isTaker => role.toLowerCase() == 'taker';

  bool get isExecuted => status.toLowerCase() == 'executed';
  bool get isPendingAccept => status.toLowerCase() == 'pending_accept';
  bool get isFailed => status.toLowerCase() == 'failed';
  bool get isExpired => status.toLowerCase() == 'expired';

  Map<String, dynamic> toJson() => {
    'trade_id': tradeId,
    'dlc_id': dlcId,
    'role': role,
    if (counterpartyOrderId != null)
      'counterparty_order_id': counterpartyOrderId,
    if (quantity != null) 'quantity': quantity,
    if (price != null) 'price': price,
    'status': status,
    if (reservedAt != null) 'reserved_at': reservedAt!.toIso8601String(),
    if (executedAt != null) 'executed_at': executedAt!.toIso8601String(),
    if (dlcStatus != null) 'dlc_status': dlcStatus,
    if (fundingTxid != null) 'funding_txid': fundingTxid,
    if (closingTxid != null) 'closing_txid': closingTxid,
    if (refundTxid != null) 'refund_txid': refundTxid,
    if (lastErrorReason != null) 'last_error_reason': lastErrorReason,
    if (lastErrorMessage != null) 'last_error_message': lastErrorMessage,
  };

  static DlcOrderExecution? tryFromJson(dynamic value) {
    if (value is! Map) return null;
    final map = Map<String, dynamic>.from(value);

    final tradeId = (map['trade_id'] as String?)?.trim();
    final dlcId = (map['dlc_id'] as String?)?.trim();
    final role = (map['role'] as String?)?.trim();
    final status = (map['status'] as String?)?.trim();
    if (tradeId == null || tradeId.isEmpty) return null;
    if (dlcId == null || dlcId.isEmpty) return null;
    if (role == null || role.isEmpty) return null;
    if (status == null || status.isEmpty) return null;

    double? toDouble(dynamic raw) {
      if (raw is num) return raw.toDouble();
      if (raw is String) return double.tryParse(raw.trim());
      return null;
    }

    DateTime? toDate(dynamic raw) {
      if (raw == null) return null;
      return DateTime.tryParse(raw.toString());
    }

    return DlcOrderExecution(
      tradeId: tradeId,
      dlcId: dlcId,
      role: role,
      counterpartyOrderId: (map['counterparty_order_id'] as String?)?.trim(),
      quantity: toDouble(map['quantity']),
      price: toDouble(map['price']),
      status: status,
      reservedAt: toDate(map['reserved_at']),
      executedAt: toDate(map['executed_at']),
      dlcStatus: (map['dlc_status'] as String?)?.trim(),
      fundingTxid: (map['funding_txid'] as String?)?.trim(),
      closingTxid: (map['closing_txid'] as String?)?.trim(),
      refundTxid: (map['refund_txid'] as String?)?.trim(),
      lastErrorReason: (map['last_error_reason'] as String?)?.trim(),
      lastErrorMessage: (map['last_error_message'] as String?)?.trim(),
    );
  }
}

/// Canonical DLC summary returned by `GET /dlcs/{dlc_id}` and related routes.
///
/// Both wallets reference the same record. The local wallet's role is derived
/// from comparing its own order id against [makerOrderId] / [takerOrderId].
class DlcCanonicalDlcInfo {
  final String dlcId;
  final String tradeId;
  final String makerOrderId;
  final String takerOrderId;
  final String status;

  const DlcCanonicalDlcInfo({
    required this.dlcId,
    required this.tradeId,
    required this.makerOrderId,
    required this.takerOrderId,
    required this.status,
  });

  /// Returns 'maker' or 'taker' for [orderId], or null when the order is not
  /// part of this DLC.
  String? roleForOrderId(String orderId) {
    if (orderId == makerOrderId) return 'maker';
    if (orderId == takerOrderId) return 'taker';
    return null;
  }

  static DlcCanonicalDlcInfo? tryFromJson(dynamic value) {
    if (value is! Map) return null;
    final map = Map<String, dynamic>.from(value);
    final dlcId = (map['dlc_id'] as String?)?.trim();
    final tradeId = (map['trade_id'] as String?)?.trim();
    final maker = (map['maker_order_id'] as String?)?.trim();
    final taker = (map['taker_order_id'] as String?)?.trim();
    final status = (map['status'] as String?)?.trim();
    if (dlcId == null || dlcId.isEmpty) return null;
    if (tradeId == null || tradeId.isEmpty) return null;
    if (maker == null || maker.isEmpty) return null;
    if (taker == null || taker.isEmpty) return null;
    if (status == null || status.isEmpty) return null;
    return DlcCanonicalDlcInfo(
      dlcId: dlcId,
      tradeId: tradeId,
      makerOrderId: maker,
      takerOrderId: taker,
      status: status,
    );
  }
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
  final double? filledQuantity;
  final double? remainingQuantity;
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

  /// Draft offer hex for orders that are still resting (no match yet).
  /// `null` once an execution exists.
  final String? draftOfferObjectHex;

  /// Full match attempt history. Empty for a fresh resting order.
  ///
  /// Latest entry (last item) drives current `dlcId`, `dlcStatus`, role,
  /// funding/settlement txids, etc. for UI display.
  final List<DlcOrderExecution> executions;

  const DlcOrderSummary({
    required this.orderId,
    required this.dlcId,
    required this.status,
    required this.pendingMatchAccept,
    this.inFlightPhase,
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
    this.filledQuantity,
    this.remainingQuantity,
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
    this.draftOfferObjectHex,
    this.executions = const <DlcOrderExecution>[],
  });

  /// Latest execution attempt. `null` for orders that never matched.
  DlcOrderExecution? get latestExecution =>
      executions.isEmpty ? null : executions.last;

  /// Most recent successful (`executed`) match. `null` until a match succeeds.
  DlcOrderExecution? get lastSuccessfulExecution {
    for (var i = executions.length - 1; i >= 0; i -= 1) {
      if (executions[i].isExecuted) return executions[i];
    }
    return null;
  }

  /// True when the order has at least one match attempt (any status).
  bool get hasMatchHistory => executions.isNotEmpty;

  DlcOrderSummary copyWith({
    String? orderId,
    String? dlcId,
    String? status,
    bool? pendingMatchAccept,
    DlcOrderInFlightPhase? inFlightPhase,
    bool clearInFlightPhase = false,
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
    double? filledQuantity,
    double? remainingQuantity,
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
    String? draftOfferObjectHex,
    List<DlcOrderExecution>? executions,
  }) {
    return DlcOrderSummary(
      orderId: orderId ?? this.orderId,
      dlcId: dlcId ?? this.dlcId,
      status: status ?? this.status,
      pendingMatchAccept: pendingMatchAccept ?? this.pendingMatchAccept,
      inFlightPhase: clearInFlightPhase
          ? null
          : (inFlightPhase ?? this.inFlightPhase),
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
      filledQuantity: filledQuantity ?? this.filledQuantity,
      remainingQuantity: remainingQuantity ?? this.remainingQuantity,
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
      draftOfferObjectHex: draftOfferObjectHex ?? this.draftOfferObjectHex,
      executions: executions ?? this.executions,
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
