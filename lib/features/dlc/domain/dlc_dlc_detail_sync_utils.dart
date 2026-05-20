import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_negotiation_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_in_flight.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_utils.dart';

/// How long to reuse a cached `GET /dlcs/{id}` response for an active contract.
const Duration dlcLiveDlcDetailCacheTtl = Duration(seconds: 30);

/// How long to reuse cached DLC detail for settled / terminal contracts.
const Duration dlcClosedDlcDetailCacheTtl = Duration(hours: 24);

/// Whether [GET /orders] already has enough for UI — skip `GET /dlcs/{id}`.
bool coordinatorOrderJsonSkipsDlcDetailFetch(Map<String, dynamic> json) {
  final order = _orderSummaryFromCoordinatorJson(json);
  if (order.dlcId == null || order.dlcId!.isEmpty) return true;
  if (isDlcOpenOrder(order)) return true;
  if (!isDlcClosedOrder(order)) return false;
  return _orderListHasCompleteClosedDlcSnapshot(order);
}

bool _orderListHasCompleteClosedDlcSnapshot(DlcOrderSummary order) {
  final closing = order.closingTxid;
  if (closing != null && closing.isNotEmpty) return true;
  final refund = order.refundTxid;
  if (refund != null && refund.isNotEmpty) return true;
  final outcome = order.oracleOutcomeValue;
  return outcome != null && outcome.isNotEmpty;
}

/// Whether the app should call `GET /dlcs/{dlc_id}` for this order right now.
bool orderShouldFetchDlcDetail(
  DlcOrderSummary order, {
  required bool forceRefresh,
}) {
  if (forceRefresh) return order.dlcId != null && order.dlcId!.isNotEmpty;
  final dlcId = order.dlcId;
  if (dlcId == null || dlcId.isEmpty) return false;

  if (needsDlcNegotiation(order)) return true;
  if (order.inFlightPhase != null) return true;

  if (isDlcClosedOrder(order)) {
    return !_orderListHasCompleteClosedDlcSnapshot(order);
  }

  if (isDlcLiveOrder(order) || isDlcPendingMatchAcceptPhase(order)) {
    return true;
  }

  if (isDlcOpenOrder(order)) return false;

  return false;
}

/// Returns true when a cached DLC detail response can be reused.
bool isDlcDetailCacheFresh({
  required DateTime fetchedAt,
  required DlcOrderSummary order,
  String? detailUpdatedAt,
  DateTime? now,
}) {
  final clock = now ?? DateTime.now().toUtc();
  final age = clock.difference(fetchedAt.toUtc());
  if (isDlcClosedOrder(order)) {
    return age < dlcClosedDlcDetailCacheTtl;
  }
  if (needsDlcNegotiation(order) ||
      isDlcLiveOrder(order) ||
      isDlcPendingMatchAcceptPhase(order)) {
    return age < dlcLiveDlcDetailCacheTtl;
  }
  return age < dlcClosedDlcDetailCacheTtl;
}

bool orderNeedsBackgroundStatusPoll(DlcOrderSummary order) {
  if (isDlcClosedOrder(order)) return false;
  if (needsDlcNegotiation(order)) return true;
  if (orderShowsInOpenSection(order) || orderShowsInLiveSection(order)) {
    return true;
  }
  return false;
}

/// True when [GET /orders] has newer DLC snapshot fields than a cached enrichment.
bool listDlcSnapshotAheadOfCached({
  required DlcOrderSummary list,
  required DlcOrderSummary cached,
}) {
  if (list.status.toLowerCase() != cached.status.toLowerCase()) return true;

  final listDlc = list.dlcStatus?.toLowerCase();
  final cachedDlc = cached.dlcStatus?.toLowerCase();
  if (listDlc != cachedDlc &&
      listDlc != null &&
      listDlc.isNotEmpty) {
    return true;
  }

  if (_nonEmpty(list.fundingTxid) != _nonEmpty(cached.fundingTxid)) {
    return _nonEmpty(list.fundingTxid);
  }
  if (_nonEmpty(list.closingTxid) != _nonEmpty(cached.closingTxid)) {
    return _nonEmpty(list.closingTxid);
  }
  if (_nonEmpty(list.refundTxid) != _nonEmpty(cached.refundTxid)) {
    return _nonEmpty(list.refundTxid);
  }

  final listOutcome = list.oracleOutcomeValue?.trim();
  final cachedOutcome = cached.oracleOutcomeValue?.trim();
  if (listOutcome != null &&
      listOutcome.isNotEmpty &&
      listOutcome != cachedOutcome) {
    return true;
  }

  return false;
}

/// Combines a fresh coordinator list row with DLC-detail enrichment.
///
/// List fields (status, match, sign flags, protocol status) win when present;
/// DLC-only economics and txids fall back to [enriched].
DlcOrderSummary mergeListOrderWithDlcEnrichment({
  required DlcOrderSummary list,
  required DlcOrderSummary enriched,
}) {
  return DlcOrderSummary(
    orderId: list.orderId,
    dlcId: list.dlcId,
    status: list.status,
    pendingMatchAccept: list.pendingMatchAccept,
    inFlightPhase: list.inFlightPhase,
    matchedOrderId: list.matchedOrderId,
    matchedDlcId: list.matchedDlcId,
    isMaker: list.isMaker,
    matchRole: list.matchRole,
    signRequired: list.signRequired,
    dlcStatus: _preferNonEmptyString(list.dlcStatus, enriched.dlcStatus),
    settlementType: _preferNonEmptyString(
      list.settlementType,
      enriched.settlementType,
    ),
    confirmationStatus: _preferNonEmptyString(
      list.confirmationStatus,
      enriched.confirmationStatus,
    ),
    instrumentId: list.instrumentId ?? enriched.instrumentId,
    side: list.side ?? enriched.side,
    quantity: list.quantity ?? enriched.quantity,
    price: list.price ?? enriched.price,
    createdAt: list.createdAt ?? enriched.createdAt,
    sideCollateralSat: list.sideCollateralSat ?? enriched.sideCollateralSat,
    partnerFeeSat: list.partnerFeeSat ?? enriched.partnerFeeSat,
    networkFeeSat: list.networkFeeSat ?? enriched.networkFeeSat,
    lastErrorReason: _preferNonEmptyString(
      list.lastErrorReason,
      enriched.lastErrorReason,
    ),
    lastErrorMessage: _preferNonEmptyString(
      list.lastErrorMessage,
      enriched.lastErrorMessage,
    ),
    oracleOutcomeValue: _preferNonEmptyString(
      list.oracleOutcomeValue,
      enriched.oracleOutcomeValue,
    ),
    fundingTxid: _preferNonEmptyString(list.fundingTxid, enriched.fundingTxid),
    closingTxid: _preferNonEmptyString(list.closingTxid, enriched.closingTxid),
    refundTxid: _preferNonEmptyString(list.refundTxid, enriched.refundTxid),
  );
}

bool _nonEmpty(String? value) => value != null && value.isNotEmpty;

String? _preferNonEmptyString(String? primary, String? fallback) {
  if (primary != null && primary.isNotEmpty) return primary;
  return fallback;
}

DlcOrderSummary _orderSummaryFromCoordinatorJson(Map<String, dynamic> json) {
  return DlcOrderSummary(
    orderId: json['order_id']?.toString() ?? '',
    dlcId: json['dlc_id'] as String?,
    status: json['status']?.toString() ?? '',
    pendingMatchAccept: json['pending_match_accept'] == true,
    matchedOrderId: json['matched_order_id'] as String?,
    matchedDlcId: json['matched_dlc_id'] as String?,
    isMaker: json['is_maker'] as bool?,
    matchRole: json['match_role'] as String?,
    signRequired: json['sign_required'] as bool?,
    dlcStatus: json['dlc_status'] as String?,
    settlementType: json['settlement_type'] as String?,
    confirmationStatus: json['confirmation_status'] as String?,
    instrumentId: json['instrument_id'] as String?,
    side: json['side'] as String?,
    quantity: json['quantity'] is num ? (json['quantity'] as num).toDouble() : null,
    price: json['price'] is num ? (json['price'] as num).toDouble() : null,
    createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    sideCollateralSat: null,
    partnerFeeSat: null,
    networkFeeSat: null,
    lastErrorReason: json['last_error_reason'] as String?,
    lastErrorMessage: json['last_error_message'] as String?,
    oracleOutcomeValue: json['oracle_outcome_value'] as String?,
    fundingTxid: json['funding_txid'] as String?,
    closingTxid: json['closing_txid'] as String?,
    refundTxid: json['refund_txid'] as String?,
  );
}
