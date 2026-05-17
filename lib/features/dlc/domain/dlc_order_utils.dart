import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:intl/intl.dart';

/// Coordinator JSON [price]: integer satoshis when ≥ 1, else BTC fraction (0 < x < 1).
/// Semantics (line total vs per contract) depend on the endpoint; see
/// [dlcOrderbookPremiumPerFullContractSatoshis] for orderbook rows.
int? dlcPremiumPerContractSatoshisFromCoordinatorRaw(Object? raw) {
  if (raw == null) return null;
  final num? n = raw is num ? raw : num.tryParse(raw.toString().trim());
  if (n == null || n < 0) return null;
  if (n == 0) return 0;
  final d = n.toDouble();
  if (d > 0 && d < 1.0) {
    return (d * 100000000).round();
  }
  return d.round();
}

double? dlcParseOrderbookRowQuantity(Map<String, dynamic> row) {
  final qtyRaw = row['quantity'] ?? row['amount'];
  if (qtyRaw is num) return qtyRaw.toDouble();
  return double.tryParse(qtyRaw?.toString().trim() ?? '');
}

/// Orderbook row: [price] is premium for the row's aggregated [quantity];
/// returns premium for **one full contract** (same unit as Create order premium).
int? dlcOrderbookPremiumPerFullContractSatoshis(Map<String, dynamic> row) {
  final lineSats = dlcPremiumPerContractSatoshisFromCoordinatorRaw(
    row['price'],
  );
  if (lineSats == null) return null;
  final qty = dlcParseOrderbookRowQuantity(row);
  if (qty == null || qty <= 0) return lineSats;
  return (lineSats / qty).round();
}

String dlcFormatGroupedSatoshis(int? sats) {
  if (sats == null) return '-';
  return NumberFormat('#,##0', 'en_US').format(sats);
}

/// Premium per contract for UI (grouped, no decimals).
String dlcFormatOrderPremiumPerContract(DlcOrderSummary order) {
  final sats = dlcPremiumPerContractSatoshisFromCoordinatorRaw(order.price);
  return dlcFormatGroupedSatoshis(sats);
}

/// Maker / Taker label for order list and detail (never empty when role can be inferred).
String formatDlcOrderRole(DlcOrderSummary order) {
  final inferred = inferDlcOrderMatchRole(order);
  if (inferred == 'maker') return 'Maker';
  if (inferred == 'taker') return 'Taker';
  return '-';
}

/// Resolves `maker` / `taker` from coordinator fields and book lifecycle heuristics.
String? inferDlcOrderMatchRole(DlcOrderSummary order) {
  final explicitRole = order.matchRole?.toLowerCase().trim();
  if (explicitRole == 'maker' || explicitRole == 'taker') {
    return explicitRole;
  }
  if (order.isMaker == true) return 'maker';
  if (order.isMaker == false) return 'taker';
  if (order.pendingMatchAccept) return 'taker';

  final status = order.status.toLowerCase();
  final hasMatch =
      order.matchedOrderId != null && order.matchedOrderId!.isNotEmpty;

  if (status == 'open' && !hasMatch) {
    return 'maker';
  }
  if (hasMatch && status == 'pending_accept') {
    return 'maker';
  }
  return null;
}

/// Book / match lifecycle — coordinator `order.status`.
bool isDlcOpenOrder(DlcOrderSummary order) {
  final status = order.status.toLowerCase();
  return status == 'open' ||
      status == 'pending_accept' ||
      order.pendingMatchAccept;
}

/// Terminal market or protocol states.
bool isDlcClosedOrder(DlcOrderSummary order) {
  final orderStatus = order.status.toLowerCase();
  if (orderStatus == 'cancelled' ||
      orderStatus == 'expired' ||
      orderStatus == 'rejected') {
    return true;
  }
  return _isTerminalDlcStatus(order.dlcStatus?.toLowerCase());
}

/// Active matched contract — coordinator `order.status` is usually `filled`;
/// protocol progress is on [DlcOrderSummary.dlcStatus].
bool isDlcLiveOrder(DlcOrderSummary order) {
  if (isDlcOpenOrder(order) || isDlcClosedOrder(order)) {
    return false;
  }

  final orderStatus = order.status.toLowerCase();
  final dlcStatus = order.dlcStatus?.toLowerCase();

  if (orderStatus == 'filled') {
    if (order.dlcId == null) {
      return true;
    }
    if (dlcStatus == null || dlcStatus.isEmpty) {
      return true;
    }
    return _isActiveDlcStatus(dlcStatus);
  }

  if (order.dlcId != null && _isActiveDlcStatus(dlcStatus)) {
    return true;
  }

  return false;
}

bool _isTerminalDlcStatus(String? dlcStatus) {
  if (dlcStatus == null || dlcStatus.isEmpty) {
    return false;
  }
  return dlcStatus.contains('closed') ||
      dlcStatus.contains('settled') ||
      dlcStatus == 'terminated';
}

bool _isActiveDlcStatus(String? dlcStatus) {
  if (dlcStatus == null || dlcStatus.isEmpty) {
    return false;
  }
  switch (dlcStatus) {
    case 'offer_created':
    case 'accepted':
    case 'signed':
    case 'matured':
    case 'attested':
    case 'cet_broadcasted':
    case 'refund_broadcasted':
      return true;
    default:
      return false;
  }
}
