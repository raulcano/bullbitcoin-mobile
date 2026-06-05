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

DlcStrikeOrderbookSnapshot dlcBuildStrikeOrderbookSnapshot({
  required double strikePrice,
  required List<Map<String, dynamic>> bids,
  required List<Map<String, dynamic>> asks,
}) {
  return DlcStrikeOrderbookSnapshot(
    strikePrice: strikePrice,
    bids: bids,
    asks: asks,
    lowestAskPremiumSats: dlcOrderbookLowestAskPremiumSats(asks),
    highestBidPremiumSats: dlcOrderbookHighestBidPremiumSats(bids),
  );
}

/// Lowest per-contract premium on the ask side (best ask for a buyer).
int? dlcOrderbookLowestAskPremiumSats(List<Map<String, dynamic>> asks) {
  int? lowest;
  for (final row in asks) {
    final premium = dlcOrderbookPremiumPerFullContractSatoshis(row);
    if (premium == null) continue;
    if (lowest == null || premium < lowest) lowest = premium;
  }
  return lowest;
}

/// Highest per-contract premium on the bid side (best bid for a seller).
int? dlcOrderbookHighestBidPremiumSats(List<Map<String, dynamic>> bids) {
  int? highest;
  for (final row in bids) {
    final premium = dlcOrderbookPremiumPerFullContractSatoshis(row);
    if (premium == null) continue;
    if (highest == null || premium > highest) highest = premium;
  }
  return highest;
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

/// Coordinator option convention: seller posts 1 BTC collateral per contract.
const int dlcSatsPerOptionContract = 100000000;

double? _readCollateralField(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
      if (parsed != null) return parsed;
    }
  }
  return null;
}

/// Seller (short) BTC collateral for an order — same for both parties in a match.
double? dlcSellerCollateralSats({
  Map<String, dynamic>? json,
  String? side,
  double? quantity,
}) {
  if (json != null) {
    final explicit = _readCollateralField(json, [
      'seller_collateral_sats',
      'seller_collateral_sat',
      'sell_collateral_sats',
      'short_collateral_sats',
    ]);
    if (explicit != null && explicit > 0) return explicit;

    final sideLower = side?.toLowerCase();
    if (sideLower == 'buy') {
      final acceptor = _readCollateralField(json, [
        'acceptor_collateral_sats',
        'acceptor_collateral_sat',
      ]);
      if (acceptor != null && acceptor > 0) return acceptor;
    } else if (sideLower == 'sell') {
      final offerer = _readCollateralField(json, [
        'offerer_collateral_sats',
        'offerer_collateral_sat',
      ]);
      if (offerer != null && offerer > 0) return offerer;
    }

    final shortCollateral = _readCollateralField(json, [
      'collateral_sats',
      'collateral_sat',
    ]);
    if (shortCollateral != null && shortCollateral > 0) {
      return shortCollateral;
    }
  }

  if (quantity != null && quantity > 0) {
    return quantity * dlcSatsPerOptionContract;
  }
  return null;
}

/// Seller collateral on [DlcOrderSummary] (stored in [DlcOrderSummary.sideCollateralSat]).
double? dlcOrderSellerCollateralSats(DlcOrderSummary order) {
  return order.sideCollateralSat;
}

String dlcFormatOrderSellerCollateral(DlcOrderSummary order) {
  return dlcFormatGroupedSatoshis(
    dlcOrderSellerCollateralSats(order)?.round(),
  );
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

/// Resting on the coordinator orderbook (`open` only, not pending match).
bool isDlcOpenOrderOnOrderbook(DlcOrderSummary order) {
  return order.status.toLowerCase() == 'open';
}

/// Order ids attached to a coordinator orderbook row, when present.
Set<String> dlcOrderbookRowOrderIds(Map<String, dynamic> row) {
  final ids = <String>{};
  final orderId = row['order_id']?.toString().trim();
  if (orderId != null && orderId.isNotEmpty) {
    ids.add(orderId);
  }
  final orderIds = row['order_ids'];
  if (orderIds is List) {
    for (final id in orderIds) {
      final value = id?.toString().trim();
      if (value != null && value.isNotEmpty) {
        ids.add(value);
      }
    }
  }
  return ids;
}

/// Per-contract premium candidates for a book row (line total vs per-contract encoding).
Set<int> dlcOrderbookRowPerContractPriceCandidates(Map<String, dynamic> row) {
  final raw = dlcPremiumPerContractSatoshisFromCoordinatorRaw(row['price']);
  if (raw == null) return const {};

  final qty = dlcParseOrderbookRowQuantity(row);
  final candidates = <int>{raw};
  if (qty != null && qty > 0) {
    candidates.add((raw / qty).round());
  }
  return candidates;
}

bool dlcOrderbookRowPriceMatchesOrder({
  required Map<String, dynamic> row,
  required int? orderPerContractSats,
}) {
  if (orderPerContractSats == null) return false;
  return dlcOrderbookRowPerContractPriceCandidates(
    row,
  ).contains(orderPerContractSats);
}

/// True when [row] matches an [orders] entry from the active wallet on this book side.
///
/// Coordinator books: buy → bids, sell → asks. [isAskRow] is true for the asks table.
///
/// When the row has no order id, matches at the price level: supports multiple own
/// orders at the same premium and aggregated book rows whose quantity is the sum of
/// yours. Avoids underlining when another participant has the same per-order quote.
bool dlcOrderbookRowIsOwnWalletOpenOrder({
  required Map<String, dynamic> row,
  required bool isAskRow,
  required List<DlcOrderSummary> orders,
  required List<Map<String, dynamic>> orderbookSideRows,
  String? selectedInstrumentId,
}) {
  final rowIds = dlcOrderbookRowOrderIds(row);
  if (rowIds.isNotEmpty) {
    for (final order in orders) {
      if (!isDlcOpenOrderOnOrderbook(order)) continue;
      if (!rowIds.contains(order.orderId)) continue;
      if (!_orderMatchesOrderbookSide(
        order: order,
        isAskRow: isAskRow,
        rowInstrumentId: row['instrument_id']?.toString(),
        selectedInstrumentId: selectedInstrumentId,
      )) {
        continue;
      }
      return true;
    }
    return false;
  }

  final rowQty = dlcParseOrderbookRowQuantity(row);
  if (rowQty == null || rowQty <= 0) return false;
  if (dlcOrderbookRowPerContractPriceCandidates(row).isEmpty) return false;

  final ordersAtLevel = _openOrdersAtOrderbookPriceLevel(
    row: row,
    isAskRow: isAskRow,
    orders: orders,
    selectedInstrumentId: selectedInstrumentId,
  );
  if (ordersAtLevel.isEmpty) return false;

  final rowsAtLevel = _orderbookRowsAtPriceLevel(
    row: row,
    orderbookSideRows: orderbookSideRows,
    selectedInstrumentId: selectedInstrumentId,
  );

  // Single aggregated row: total resting qty at this premium equals the row.
  if (rowsAtLevel.length == 1) {
    final myTotalQty = ordersAtLevel.fold<double>(
      0,
      (sum, order) => sum + (order.quantity ?? 0),
    );
    if ((myTotalQty - rowQty).abs() < 1e-9) {
      return true;
    }
  }

  // One book row per order: only underline when row counts match at this qty.
  final rowsWithQty = rowsAtLevel
      .where((bookRow) => _orderbookRowQuantityEquals(rowQty, bookRow))
      .length;
  final myOrdersWithQty = ordersAtLevel
      .where(
        (order) =>
            order.quantity != null &&
            _quantitiesEqual(rowQty, order.quantity!),
      )
      .length;
  if (myOrdersWithQty == 0) return false;

  return rowsWithQty == myOrdersWithQty;
}

List<DlcOrderSummary> _openOrdersAtOrderbookPriceLevel({
  required Map<String, dynamic> row,
  required bool isAskRow,
  required List<DlcOrderSummary> orders,
  required String? selectedInstrumentId,
}) {
  final rowInstrumentId = row['instrument_id']?.toString();
  if (dlcOrderbookRowPerContractPriceCandidates(row).isEmpty) return const [];

  final matched = <DlcOrderSummary>[];
  for (final order in orders) {
    if (!isDlcOpenOrderOnOrderbook(order)) continue;
    if (!_orderMatchesOrderbookSide(
      order: order,
      isAskRow: isAskRow,
      rowInstrumentId: rowInstrumentId,
      selectedInstrumentId: selectedInstrumentId,
    )) {
      continue;
    }

    final orderPricePerContract =
        dlcPremiumPerContractSatoshisFromCoordinatorRaw(order.price);
    if (!dlcOrderbookRowPriceMatchesOrder(
      row: row,
      orderPerContractSats: orderPricePerContract,
    )) {
      continue;
    }

    matched.add(order);
  }
  return matched;
}

List<Map<String, dynamic>> _orderbookRowsAtPriceLevel({
  required Map<String, dynamic> row,
  required List<Map<String, dynamic>> orderbookSideRows,
  required String? selectedInstrumentId,
}) {
  return orderbookSideRows
      .where(
        (bookRow) => dlcOrderbookRowsSharePriceLevel(
          left: row,
          right: bookRow,
          selectedInstrumentId: selectedInstrumentId,
        ),
      )
      .toList(growable: false);
}

bool _quantitiesEqual(double left, double right) => (left - right).abs() < 1e-9;

bool _orderbookRowQuantityEquals(double qty, Map<String, dynamic> row) {
  final rowQty = dlcParseOrderbookRowQuantity(row);
  return rowQty != null && _quantitiesEqual(qty, rowQty);
}

/// Same instrument and per-contract premium (quantity may differ).
bool dlcOrderbookRowsSharePriceLevel({
  required Map<String, dynamic> left,
  required Map<String, dynamic> right,
  String? selectedInstrumentId,
}) {
  final priceLeft = dlcOrderbookRowPerContractPriceCandidates(left);
  final priceRight = dlcOrderbookRowPerContractPriceCandidates(right);
  if (priceLeft.isEmpty ||
      priceRight.isEmpty ||
      priceLeft.intersection(priceRight).isEmpty) {
    return false;
  }

  final instLeft = left['instrument_id']?.toString();
  final instRight = right['instrument_id']?.toString();
  if (instLeft != null &&
      instLeft.isNotEmpty &&
      instRight != null &&
      instRight.isNotEmpty) {
    return instLeft == instRight;
  }
  if (selectedInstrumentId == null || selectedInstrumentId.isEmpty) {
    return true;
  }
  final leftInst = instLeft?.isNotEmpty == true ? instLeft : selectedInstrumentId;
  final rightInst = instRight?.isNotEmpty == true ? instRight : selectedInstrumentId;
  return leftInst == rightInst;
}

bool _orderMatchesOrderbookSide({
  required DlcOrderSummary order,
  required bool isAskRow,
  required String? rowInstrumentId,
  required String? selectedInstrumentId,
}) {
  final side = order.side?.toLowerCase();
  if (side == null) return false;
  final orderOnAskSide = side == 'sell';
  if (orderOnAskSide != isAskRow) return false;
  return _orderbookInstrumentMatches(
    orderInstrumentId: order.instrumentId,
    rowInstrumentId: rowInstrumentId,
    selectedInstrumentId: selectedInstrumentId,
  );
}

/// Same instrument, quantity, and per-contract premium on the coordinator book.
bool dlcOrderbookRowsShareCharacteristics({
  required Map<String, dynamic> left,
  required Map<String, dynamic> right,
  String? selectedInstrumentId,
}) {
  final qtyLeft = dlcParseOrderbookRowQuantity(left);
  final qtyRight = dlcParseOrderbookRowQuantity(right);
  if (qtyLeft == null ||
      qtyRight == null ||
      qtyLeft <= 0 ||
      (qtyLeft - qtyRight).abs() > 1e-9) {
    return false;
  }

  final priceLeft = dlcOrderbookRowPerContractPriceCandidates(left);
  final priceRight = dlcOrderbookRowPerContractPriceCandidates(right);
  if (priceLeft.isEmpty ||
      priceRight.isEmpty ||
      priceLeft.intersection(priceRight).isEmpty) {
    return false;
  }

  final instLeft = left['instrument_id']?.toString();
  final instRight = right['instrument_id']?.toString();
  if (instLeft != null &&
      instLeft.isNotEmpty &&
      instRight != null &&
      instRight.isNotEmpty) {
    return instLeft == instRight;
  }
  if (selectedInstrumentId == null || selectedInstrumentId.isEmpty) {
    return true;
  }
  final leftInst = instLeft?.isNotEmpty == true ? instLeft : selectedInstrumentId;
  final rightInst = instRight?.isNotEmpty == true ? instRight : selectedInstrumentId;
  return leftInst == rightInst;
}

bool _orderbookInstrumentMatches({
  required String? orderInstrumentId,
  required String? rowInstrumentId,
  required String? selectedInstrumentId,
}) {
  final bookInstrumentId =
      rowInstrumentId != null && rowInstrumentId.isNotEmpty
      ? rowInstrumentId
      : selectedInstrumentId;
  if (bookInstrumentId == null || bookInstrumentId.isEmpty) {
    return false;
  }
  if (orderInstrumentId == null || orderInstrumentId.isEmpty) {
    return true;
  }
  return orderInstrumentId == bookInstrumentId;
}

/// Resting on the orderbook, not yet in the post-match accept/sign flow.
bool isDlcOpenOrder(DlcOrderSummary order) {
  if (isDlcClosedOrder(order)) return false;
  return order.status.toLowerCase() == 'open';
}

/// Matched and awaiting accept/sign, or filled with an active DLC.
bool isDlcPendingMatchAcceptPhase(DlcOrderSummary order) {
  if (isDlcClosedOrder(order)) return false;
  final status = order.status.toLowerCase();
  return status == 'pending_accept' || order.pendingMatchAccept;
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
  if (isDlcClosedOrder(order) || isDlcOpenOrder(order)) {
    return false;
  }

  if (isDlcPendingMatchAcceptPhase(order)) {
    return true;
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
  switch (dlcStatus) {
    case 'cet_broadcasted':
    case 'refund_broadcasted':
    case 'cet_closed':
    case 'refund_closed':
    case 'terminated':
      return true;
    default:
      return dlcStatus.contains('closed') || dlcStatus.contains('settled');
  }
}

bool _isActiveDlcStatus(String? dlcStatus) {
  if (dlcStatus == null || dlcStatus.isEmpty) {
    return false;
  }
  if (_isTerminalDlcStatus(dlcStatus)) {
    return false;
  }
  switch (dlcStatus) {
    case 'offer_created':
    case 'accepted':
    case 'signed':
    case 'funding_broadcasted':
    case 'matured':
    case 'attested':
      return true;
    default:
      return false;
  }
}

String formatDlcStatusLabel(DlcOrderSummary order) {
  final status = order.dlcStatus?.trim();
  if (status == null || status.isEmpty) return '-';

  final normalized = status.toLowerCase();
  if (normalized == 'signed') {
    if (order.lastErrorReason?.toLowerCase() == 'funding_broadcast_failed') {
      return 'Funding broadcast failed';
    }
    return 'Funding broadcast pending';
  }
  if (normalized == 'funding_broadcasted') {
    return 'Funding broadcasted, awaiting oracle maturity';
  }

  return status;
}

/// A coordinator transaction link for mempool.space.
class DlcMempoolTxLink {
  const DlcMempoolTxLink({required this.label, required this.url});

  final String label;
  final String url;
}

bool _hasNonEmptyTxid(String? txid) => txid != null && txid.trim().isNotEmpty;

String dlcMempoolExplorerTxUrl({
  required String txid,
  required bool isTestnet,
}) {
  final normalized = txid.trim();
  if (isTestnet) {
    return 'https://mempool.space/testnet/tx/$normalized';
  }
  return 'https://mempool.space/tx/$normalized';
}

/// True when a live order has a funding tx that can be opened on mempool.space.
bool orderShowsFundingTxExplorerLink(DlcOrderSummary order) {
  if (!_hasNonEmptyTxid(order.fundingTxid)) return false;

  final dlcStatus = order.dlcStatus?.toLowerCase();
  return dlcStatus == 'signed' || dlcStatus == 'funding_broadcasted';
}

/// True when a closed order has a settlement or refund tx on mempool.space.
bool orderShowsSettlementTxExplorerLink(DlcOrderSummary order) {
  if (!isDlcClosedOrder(order)) return false;
  return _hasNonEmptyTxid(order.closingTxid) ||
      _hasNonEmptyTxid(order.refundTxid);
}

String dlcFundingTxMempoolExplorerUrl({
  required String fundingTxid,
  required bool isTestnet,
}) {
  return dlcMempoolExplorerTxUrl(txid: fundingTxid, isTestnet: isTestnet);
}

List<DlcMempoolTxLink> dlcOrderSettlementTxExplorerLinks(
  DlcOrderSummary order, {
  required bool isTestnet,
}) {
  if (!orderShowsSettlementTxExplorerLink(order)) return const [];

  final links = <DlcMempoolTxLink>[];
  final closing = order.closingTxid?.trim();
  if (closing != null && closing.isNotEmpty) {
    links.add(
      DlcMempoolTxLink(
        label: 'Settlement TX',
        url: dlcMempoolExplorerTxUrl(txid: closing, isTestnet: isTestnet),
      ),
    );
  }
  final refund = order.refundTxid?.trim();
  if (refund != null && refund.isNotEmpty) {
    links.add(
      DlcMempoolTxLink(
        label: 'Refund TX',
        url: dlcMempoolExplorerTxUrl(txid: refund, isTestnet: isTestnet),
      ),
    );
  }
  return links;
}

List<DlcMempoolTxLink> dlcOrderMempoolTxExplorerLinks(
  DlcOrderSummary order, {
  required bool isTestnet,
  bool includeFunding = false,
  bool includeSettlement = false,

  /// When false, include funding tx links whenever [fundingTxid] exists (info dialog).
  bool fundingLivePhaseOnly = true,
}) {
  final links = <DlcMempoolTxLink>[];
  if (includeFunding && _hasNonEmptyTxid(order.fundingTxid)) {
    final showFunding = !fundingLivePhaseOnly ||
        orderShowsFundingTxExplorerLink(order);
    if (showFunding) {
      links.add(
        DlcMempoolTxLink(
          label: 'Funding TX',
          url: dlcMempoolExplorerTxUrl(
            txid: order.fundingTxid!.trim(),
            isTestnet: isTestnet,
          ),
        ),
      );
    }
  }
  if (includeSettlement) {
    links.addAll(
      dlcOrderSettlementTxExplorerLinks(order, isTestnet: isTestnet),
    );
  }
  return links;
}

/// All mempool.space links for the order info dialog.
///
/// Role-agnostic: maker and taker rows for the same DLC see the same links
/// when coordinator txid fields match.
List<DlcMempoolTxLink> dlcOrderInfoMempoolTxExplorerLinks(
  DlcOrderSummary order, {
  required bool isTestnet,
}) {
  return [
    ...dlcOrderMempoolTxExplorerLinks(
      order,
      isTestnet: isTestnet,
      includeFunding: true,
      fundingLivePhaseOnly: false,
    ),
    ...dlcOrderSettlementTxExplorerLinks(order, isTestnet: isTestnet),
  ];
}
