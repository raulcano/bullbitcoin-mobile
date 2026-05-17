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

bool _isOrderNotFoundCoordinatorMessage(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('instrument not found')) return false;
  if (lower.contains('wallet not found')) return false;
  if (lower.contains('dlc not found')) return false;
  return lower.contains('order not found') ||
      (lower.contains('not_found') && lower.contains('order'));
}

int? _httpStatusFromErrorText(String text) {
  final match = RegExp(r'HTTP\s+(\d{3})').firstMatch(text);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// Coordinator order is waiting for this wallet to submit accept-match artifacts.
bool needsDlcTakerAccept(DlcOrderSummary order) {
  if (order.pendingMatchAccept) return true;
  return order.status.toLowerCase() == 'pending_accept';
}

bool isDlcMakerForSign(DlcOrderSummary order) {
  if (order.isMaker == true) return true;
  return order.matchRole?.toLowerCase() == 'maker';
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

/// Funding is broadcast (or later); no more accept/sign automation.
bool isDlcNegotiationComplete(DlcOrderSummary order) {
  if (order.fundingTxid != null && order.fundingTxid!.isNotEmpty) {
    return true;
  }
  final dlcStatus = order.dlcStatus?.toLowerCase();
  if (dlcStatus == null || dlcStatus.isEmpty) return false;
  switch (dlcStatus) {
    case 'signed':
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
