import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';

/// Coordinator projected wallet UTXOs after a funding or settlement broadcast.
enum DlcCoordinatorUtxoProjectionKind {
  fundingBroadcast,
  settlementBroadcast,
}

bool _hasNonEmptyTxid(String? txid) =>
    txid != null && txid.trim().isNotEmpty;

bool _isSettlementBroadcastDlcStatus(String? status) {
  final normalized = status?.toLowerCase().trim();
  return normalized == 'cet_broadcasted' || normalized == 'refund_broadcasted';
}

/// Whether [current] crossed a coordinator broadcast milestone vs [previous].
DlcCoordinatorUtxoProjectionKind? dlcCoordinatorUtxoProjectionKind({
  required DlcOrderSummary current,
  DlcOrderSummary? previous,
}) {
  if (previous == null) return null;

  if (_hasNonEmptyTxid(current.fundingTxid) &&
      !_hasNonEmptyTxid(previous.fundingTxid)) {
    return DlcCoordinatorUtxoProjectionKind.fundingBroadcast;
  }

  final statusNow = current.dlcStatus?.toLowerCase().trim();
  final statusBefore = previous.dlcStatus?.toLowerCase().trim();
  if (_isSettlementBroadcastDlcStatus(statusNow) &&
      statusNow != statusBefore) {
    return DlcCoordinatorUtxoProjectionKind.settlementBroadcast;
  }

  return null;
}

/// True when any order newly reflects coordinator post-broadcast UTXO projection.
bool dlcOrdersRequireUtxoSyncAfterProjection({
  required List<DlcOrderSummary> current,
  required List<DlcOrderSummary> previous,
}) {
  final previousById = <String, DlcOrderSummary>{
    for (final order in previous) order.orderId: order,
  };
  for (final order in current) {
    final prior = previousById[order.orderId];
    if (dlcCoordinatorUtxoProjectionKind(
          current: order,
          previous: prior,
        ) !=
        null) {
      return true;
    }
  }
  return false;
}
