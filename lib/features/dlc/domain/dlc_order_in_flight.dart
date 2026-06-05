import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_negotiation_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_utils.dart';
import 'package:flutter/material.dart';

/// UI-only phase while coordinator create / accept / sign is in progress.
enum DlcOrderInFlightPhase {
  /// POST /orders still running or coordinator validating a resting order.
  creatingOnCoordinator,

  /// Taker wallet is signing accept-match (matched create).
  takerSigningAccept,

  /// Maker's resting order was matched; waiting for taker accept.
  matchedAwaitingTakerAccept,

  /// Maker is signing the DLC after taker accept.
  makerSigningDlc,
}

const dlcLocalPendingOrderIdPrefix = 'local-pending-';

bool isDlcLocalPendingOrderId(String orderId) =>
    orderId.startsWith(dlcLocalPendingOrderIdPrefix);

/// In-flight phase stored on the order, or derived from coordinator fields.
DlcOrderInFlightPhase? effectiveOrderInFlightPhase(DlcOrderSummary order) {
  return order.inFlightPhase ?? resolveOrderInFlightPhase(order);
}

/// Whether the order row belongs in **Live** (including in-flight matched flow).
bool orderShowsInLiveSection(DlcOrderSummary order) {
  if (isDlcLiveOrder(order)) return true;
  switch (effectiveOrderInFlightPhase(order)) {
    case DlcOrderInFlightPhase.takerSigningAccept:
    case DlcOrderInFlightPhase.matchedAwaitingTakerAccept:
    case DlcOrderInFlightPhase.makerSigningDlc:
      return true;
    case DlcOrderInFlightPhase.creatingOnCoordinator:
    case null:
      return false;
  }
}

/// Whether the order row belongs in **Open** (including in-flight create).
bool orderShowsInOpenSection(DlcOrderSummary order) {
  if (orderShowsInLiveSection(order)) return false;
  if (isDlcOpenOrder(order)) return true;
  return effectiveOrderInFlightPhase(order) ==
      DlcOrderInFlightPhase.creatingOnCoordinator;
}

/// Open-order count for Overview and summaries (same rules as My orders → Open).
int dlcOpenOrdersCount(Iterable<DlcOrderSummary> orders) {
  return orders.where(orderShowsInOpenSection).length;
}

/// Live-order count for Overview charts (same rules as My orders → Live).
int dlcLiveOrdersCount(Iterable<DlcOrderSummary> orders) {
  return orders.where(orderShowsInLiveSection).length;
}

bool isMakerAwaitingTakerAccept(DlcOrderSummary order) {
  if (!isDlcMakerForSign(order)) return false;
  if (needsDlcTakerAccept(order)) return false;
  if (needsDlcMakerSign(order)) return false;
  if (isDlcNegotiationComplete(order)) return false;
  final status = order.status.toLowerCase();
  if (status != 'filled' && status != 'pending_accept') return false;
  final dlcStatus = order.dlcStatus?.toLowerCase();
  if (dlcStatus == 'signed' ||
      dlcStatus == 'funding_broadcasted' ||
      dlcStatus == 'cet_broadcasted' ||
      dlcStatus == 'refund_broadcasted' ||
      dlcStatus == 'terminated' ||
      dlcStatus == 'cet_closed' ||
      dlcStatus == 'refund_closed') {
    return false;
  }
  return true;
}

/// Taker's order is matched; accept is done; waiting for maker DLC sign.
bool isTakerAwaitingMakerSign(DlcOrderSummary order) {
  if (isDlcMakerForSign(order)) return false;
  if (needsDlcTakerAccept(order)) return false;
  if (needsDlcMakerSign(order)) return false;
  if (isDlcNegotiationComplete(order)) return false;
  if (order.status.toLowerCase() != 'filled') return false;
  if (order.pendingMatchAccept) return false;
  if (order.signRequired == false) return false;

  final dlcStatus = order.dlcStatus?.toLowerCase();
  if (dlcStatus == 'signed' ||
      dlcStatus == 'funding_broadcasted' ||
      dlcStatus == 'cet_broadcasted' ||
      dlcStatus == 'refund_broadcasted' ||
      dlcStatus == 'terminated' ||
      dlcStatus == 'cet_closed' ||
      dlcStatus == 'refund_closed') {
    return false;
  }

  final hasDlc = order.dlcId != null && order.dlcId!.isNotEmpty;
  final hasMatch =
      order.matchedOrderId != null && order.matchedOrderId!.isNotEmpty;
  return hasDlc || hasMatch;
}

/// Resolves hourglass phase from coordinator order fields (no local override).
DlcOrderInFlightPhase? resolveOrderInFlightPhase(DlcOrderSummary order) {
  if (isDlcLocalPendingOrderId(order.orderId)) {
    return order.inFlightPhase ?? DlcOrderInFlightPhase.creatingOnCoordinator;
  }
  if (isDlcClosedOrder(order) || isDlcNegotiationComplete(order)) {
    return null;
  }
  if (needsDlcTakerAccept(order)) {
    return DlcOrderInFlightPhase.takerSigningAccept;
  }
  if (needsDlcMakerSign(order)) {
    return DlcOrderInFlightPhase.makerSigningDlc;
  }
  if (isMakerAwaitingTakerAccept(order) || isTakerAwaitingMakerSign(order)) {
    return isMakerAwaitingTakerAccept(order)
        ? DlcOrderInFlightPhase.matchedAwaitingTakerAccept
        : DlcOrderInFlightPhase.makerSigningDlc;
  }
  return null;
}

/// Open-order create: hourglass only. Matched flow: hourglass + info.
bool dlcOrderShowsInfoDuringInFlight(DlcOrderInFlightPhase phase) {
  switch (phase) {
    case DlcOrderInFlightPhase.creatingOnCoordinator:
      return false;
    case DlcOrderInFlightPhase.takerSigningAccept:
    case DlcOrderInFlightPhase.matchedAwaitingTakerAccept:
    case DlcOrderInFlightPhase.makerSigningDlc:
      return true;
  }
}

Color dlcOrderInFlightHourglassColor(
  ColorScheme colorScheme,
  DlcOrderInFlightPhase phase,
) {
  switch (phase) {
    case DlcOrderInFlightPhase.creatingOnCoordinator:
    case DlcOrderInFlightPhase.takerSigningAccept:
    case DlcOrderInFlightPhase.matchedAwaitingTakerAccept:
      return colorScheme.primary;
    case DlcOrderInFlightPhase.makerSigningDlc:
      return colorScheme.tertiary;
  }
}

/// Optimistically remove or reduce matched liquidity on the local orderbook cache.
({List<Map<String, dynamic>> bids, List<Map<String, dynamic>> asks})
optimisticTrimOrderbookForMatch({
  required List<Map<String, dynamic>> bids,
  required List<Map<String, dynamic>> asks,
  required DlcOrderDraft draft,
}) {
  final perContract = draft.price.round();
  List<Map<String, dynamic>> consume(
    List<Map<String, dynamic>> rows,
    double takeQty,
  ) {
    final updated = <Map<String, dynamic>>[];
    for (final row in rows) {
      if (!dlcOrderbookRowPriceMatchesOrder(
        row: row,
        orderPerContractSats: perContract,
      )) {
        updated.add(Map<String, dynamic>.from(row));
        continue;
      }
      final copy = Map<String, dynamic>.from(row);
      final qty = dlcParseOrderbookRowQuantity(copy);
      if (qty == null || qty <= 0) {
        updated.add(copy);
        continue;
      }
      if (qty <= takeQty + 1e-9) {
        continue;
      }
      final remaining = qty - takeQty;
      copy['quantity'] = remaining;
      if (copy.containsKey('amount')) {
        copy['amount'] = remaining;
      }
      updated.add(copy);
    }
    return updated;
  }

  // Taker buy lifts asks; taker sell lifts bids.
  if (draft.side == DlcOrderSide.buy) {
    return (
      bids: bids,
      asks: consume(asks, draft.quantity),
    );
  }
  return (
    bids: consume(bids, draft.quantity),
    asks: asks,
  );
}

DlcOrderSummary applyResolvedInFlightPhase(DlcOrderSummary order) {
  final resolved = resolveOrderInFlightPhase(order);
  if (resolved == order.inFlightPhase) return order;
  return order.copyWith(inFlightPhase: resolved);
}

List<DlcOrderSummary> applyResolvedInFlightPhases(
  List<DlcOrderSummary> orders,
) {
  return orders.map(applyResolvedInFlightPhase).toList(growable: false);
}

/// Local row should stay visible until the coordinator list includes it.
bool shouldRetainLocalOrderMissingFromCoordinator(DlcOrderSummary order) {
  if (isDlcLocalPendingOrderId(order.orderId)) return true;
  if (order.inFlightPhase != null) return true;
  if (needsDlcNegotiation(order)) return true;

  final created = order.createdAt;
  if (created == null) return false;
  final age = DateTime.now().toUtc().difference(created.toUtc());
  if (age > const Duration(minutes: 10)) return false;

  switch (order.status.toLowerCase()) {
    case 'open':
    case 'pending_accept':
    case 'filled':
      return true;
    default:
      return false;
  }
}

/// Merges coordinator list with optimistic / not-yet-indexed orders from UI state.
List<DlcOrderSummary> mergeCoordinatorOrdersWithLocal({
  required List<DlcOrderSummary> coordinatorOrders,
  required List<DlcOrderSummary> currentOrders,
}) {
  final coordinatorIds = coordinatorOrders.map((o) => o.orderId).toSet();
  final merged = List<DlcOrderSummary>.from(coordinatorOrders);

  for (final local in currentOrders) {
    if (coordinatorIds.contains(local.orderId)) continue;
    if (!shouldRetainLocalOrderMissingFromCoordinator(local)) continue;
    merged.insert(0, local);
  }

  return merged;
}

String dlcOrderInFlightDialogTitle(DlcOrderInFlightPhase phase) {
  switch (phase) {
    case DlcOrderInFlightPhase.creatingOnCoordinator:
      return 'Opening order';
    case DlcOrderInFlightPhase.takerSigningAccept:
      return 'Signing acceptance';
    case DlcOrderInFlightPhase.matchedAwaitingTakerAccept:
      return 'Match in progress';
    case DlcOrderInFlightPhase.makerSigningDlc:
      return 'Maker signing';
  }
}

String dlcOrderInFlightDialogBody({
  required DlcOrderInFlightPhase phase,
  required DlcOrderSummary order,
}) {
  switch (phase) {
    case DlcOrderInFlightPhase.creatingOnCoordinator:
      return 'The coordinator is validating and opening this order. '
          'You can keep using the app; the hourglass will disappear when '
          'the order is ready.';
    case DlcOrderInFlightPhase.takerSigningAccept:
      return 'Your wallet is signing the match acceptance and the coordinator '
          'is validating it. This runs in the background; you will see an '
          'update here shortly.';
    case DlcOrderInFlightPhase.matchedAwaitingTakerAccept:
      return 'Your order was matched. The taker is signing the acceptance '
          'and the coordinator is validating it. You can keep using the app.';
    case DlcOrderInFlightPhase.makerSigningDlc:
      final role = formatDlcOrderRole(order);
      if (role == 'Maker') {
        return 'You are signing the DLC contract with your wallet. '
            'This runs in the background.';
      }
      return 'The maker is signing the DLC contract. '
          'You can keep using the app while this completes.';
  }
}

String createOrderPlacedInfoMessage({required bool matchIntent}) {
  if (matchIntent) {
    return 'The order has been placed and matched and can be checked '
        'in your list of "Live orders".';
  }
  return 'The order has been opened and can be checked '
      'in your list of "Open orders".';
}
