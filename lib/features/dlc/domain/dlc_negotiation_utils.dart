import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';

/// Persisted when GET/accept/sign confirms the order no longer exists on the coordinator.
const dlcNegotiationOrderNotFoundStatus = 'order_not_found';

bool isNegotiationAbandonedForOrderNotFound(String? negotiationStatus) {
  return negotiationStatus == dlcNegotiationOrderNotFoundStatus;
}

/// True when a coordinator API error indicates the order id is unknown (404 / not_found).
bool isCoordinatorOrderNotFound(Object error) {
  final text = error.toString();
  final status = _httpStatusFromErrorText(text);
  if (status != null && status != 404) return false;
  return _isOrderNotFoundCoordinatorMessage(text);
}

/// True when a coordinator API error indicates the DLC id is unknown (404 / not_found).
bool isCoordinatorDlcNotFound(Object error) {
  final text = error.toString();
  final status = _httpStatusFromErrorText(text);
  if (status != null && status != 404) return false;
  return _isDlcNotFoundCoordinatorMessage(text);
}

/// Order or DLC record no longer exists on the coordinator — drop local copies.
bool isCoordinatorResourceNotFound(Object error) {
  return isCoordinatorOrderNotFound(error) || isCoordinatorDlcNotFound(error);
}

bool _isOrderNotFoundCoordinatorMessage(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('instrument not found')) return false;
  if (lower.contains('wallet not found')) return false;
  if (lower.contains('dlc not found')) return false;
  return lower.contains('order not found') ||
      (lower.contains('not_found') && lower.contains('order'));
}

bool _isDlcNotFoundCoordinatorMessage(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('instrument not found')) return false;
  if (lower.contains('wallet not found')) return false;
  if (lower.contains('order not found')) return false;
  return lower.contains('dlc not found') ||
      (lower.contains('not_found') && lower.contains('dlc'));
}

int? _httpStatusFromErrorText(String text) {
  final match = RegExp(r'HTTP\s+(\d{3})').firstMatch(text);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// Coordinator order is waiting for this wallet to submit accept-match artifacts.
bool needsDlcTakerAccept(DlcOrderSummary order) {
  final status = order.status.toLowerCase();
  // Accept already landed on the coordinator; ignore stale `pending_match_accept`.
  if (status == 'filled') return false;
  if (status == 'pending_accept') return true;
  return order.pendingMatchAccept;
}

/// Coordinator rejected accept because the order already left `pending_accept`.
bool isAcceptSigningNoLongerRequired(Object error) {
  final lower = error.toString().toLowerCase();
  return lower.contains('state_conflict') &&
      (lower.contains('not awaiting accept signing') ||
          lower.contains('not awaiting accept submission'));
}

/// True when this wallet's order is the maker side of the latest match.
///
/// Latest execution is authoritative under the canonical-DLC model. Falls back
/// to per-wallet coordinator signals (`is_maker`, `match_role`, `sign_required`)
/// when no executions[] have been surfaced yet. Coordinators that have not
/// rolled out the canonical-DLC `executions[]` field continue to expose the
/// per-wallet flags above; the negotiation loop must keep working against
/// either schema.
bool isDlcMakerForSign(DlcOrderSummary order) {
  final latest = order.latestExecution;
  if (latest != null) return latest.isMaker;
  // Positive explicit signals.
  if (order.isMaker == true) return true;
  if (order.matchRole?.toLowerCase() == 'maker') return true;
  // Contradictory explicit role marker — never claim maker via fallback.
  if (order.isMaker == false) return false;
  if (order.matchRole?.toLowerCase() == 'taker') return false;
  // `sign_required` is per-wallet: the coordinator only sets it on the maker
  // side when sign-context is ready. Treat it as an authoritative maker signal
  // when the order has reached the post-accept lifecycle and no contradicting
  // role marker is present.
  if (order.signRequired == true) {
    final status = order.status.toLowerCase();
    final dlcStatus = order.dlcStatus?.toLowerCase();
    if (status == 'filled' || dlcStatus == 'accepted') return true;
  }
  return false;
}

/// True when the latest execution gives this wallet the taker role.
///
/// Falls back to per-wallet coordinator signals when no executions[] are
/// present. `pending_match_accept: true` is the documented per-wallet signal
/// that this wallet is the taker for the active match (see
/// `WALLET-API-INTEGRATION-GUIDE_BULLBITCOIN`, "Run The Taker Accept Flow").
bool isDlcTakerForAccept(DlcOrderSummary order) {
  final latest = order.latestExecution;
  if (latest != null) return latest.isTaker;
  // Positive explicit signals.
  if (order.isMaker == false) return true;
  if (order.matchRole?.toLowerCase() == 'taker') return true;
  // Contradictory explicit role marker — never claim taker via fallback.
  if (order.isMaker == true) return false;
  if (order.matchRole?.toLowerCase() == 'maker') return false;
  // Only the taker side of an active match has `pending_match_accept: true`.
  // The maker observes `pending_accept` but with `pending_match_accept: false`,
  // so this fallback never misclassifies the maker.
  if (order.pendingMatchAccept) return true;
  return false;
}

/// Maker must sign after match when DLC is accepted and coordinator requests it.
bool needsDlcMakerSign(DlcOrderSummary order) {
  if (order.dlcId == null) return false;
  if (order.signRequired != true) return false;
  if (!isDlcMakerForSign(order)) return false;

  final dlcStatus = order.dlcStatus?.toLowerCase();
  if (dlcStatus == null || dlcStatus.isEmpty) {
    return order.status.toLowerCase() == 'filled';
  }
  if (dlcStatus == 'accepted' || dlcStatus == 'offer_created') {
    return true;
  }
  return false;
}

/// Wallet-side accept/sign automation is complete.
///
/// `signed` means the coordinator accepted the SignDLCMessage; funding
/// broadcast can still be pending or failed until `funding_broadcasted` or a
/// `funding_txid` appears.
bool isDlcNegotiationComplete(DlcOrderSummary order) {
  if (order.fundingTxid != null && order.fundingTxid!.isNotEmpty) {
    return true;
  }
  final dlcStatus = order.dlcStatus?.toLowerCase();
  if (dlcStatus == null || dlcStatus.isEmpty) return false;
  switch (dlcStatus) {
    case 'signed':
    case 'funding_broadcasted':
    case 'matured':
    case 'attested':
    case 'cet_broadcasted':
    case 'refund_broadcasted':
    case 'cet_closed':
    case 'refund_closed':
    case 'terminated':
      return true;
    default:
      return false;
  }
}

/// Whether the background negotiation worker should keep polling this order.
bool needsDlcNegotiation(DlcOrderSummary order) {
  if (isDlcNegotiationComplete(order)) return false;
  return needsDlcTakerAccept(order) || needsDlcMakerSign(order);
}

bool ordersNeedDlcNegotiation(List<DlcOrderSummary> orders) {
  return orders.any(needsDlcNegotiation);
}

/// Network failures where the coordinator may still have applied the request.
bool isTransientDlcCoordinatorMessage(String text) {
  final lower = text.toLowerCase();
  return lower.contains('timeout') ||
      lower.contains('timed out') ||
      lower.contains('connection errored') ||
      lower.contains('connection error') ||
      lower.contains('no route to host') ||
      lower.contains('network is unreachable') ||
      lower.contains('failed host lookup') ||
      lower.contains('socketexception');
}

/// Negotiation worker noise that should not surface as a user-facing error.
bool isBenignDlcNegotiationMessage(String text) {
  return isTransientDlcCoordinatorMessage(text) ||
      isAcceptSigningNoLongerRequired(Exception(text));
}
