import 'package:bb_mobile/features/dlc/domain/dlc_instrument_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_option_payout_simulation.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_utils.dart';

/// Reads wallet-level PnL when the coordinator includes it on wallet/sync payloads.
int? dlcWalletPnlSatsFromCoordinatorPayload(Map<String, dynamic>? json) {
  if (json == null) return null;
  for (final key in const [
    'wallet_pnl_sats',
    'pnl_sats',
    'total_pnl_sats',
    'unrealized_pnl_sats',
  ]) {
    final value = json[key];
    if (value is num) return value.round();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
  }
  return null;
}

int? dlcOracleOutcomeUsd(DlcOrderSummary order) {
  final raw = order.oracleOutcomeValue?.trim();
  if (raw == null || raw.isEmpty) return null;
  final direct = int.tryParse(raw);
  if (direct != null) return direct;
  final asDouble = double.tryParse(raw);
  if (asDouble == null) return null;
  return asDouble.round();
}

/// Orders that can contribute to an aggregate wallet PnL estimate.
Iterable<DlcOrderSummary> dlcOrdersForWalletPnlEstimate(
  List<DlcOrderSummary> orders,
) {
  return orders.where((order) {
    if (isDlcOpenOrder(order)) return false;
    if (isDlcLiveOrder(order)) return true;
    if (!isDlcClosedOrder(order)) return false;
    return dlcOracleOutcomeUsd(order) != null;
  });
}

/// Builds a coordinator simulation request for one wallet order, if data is complete.
DlcOptionPayoutSimulationRequest? dlcOptionPayoutSimulationRequestForOrder(
  DlcOrderSummary order, {
  required int outcomePriceUsd,
}) {
  final instrumentId = order.instrumentId;
  if (instrumentId == null || instrumentId.isEmpty) return null;

  final meta = dlcInstrumentMetadata(<String, dynamic>{
    'instrument_id': instrumentId,
  });
  final right = meta.right;
  if (right == null) return null;

  final strike = dlcStrikeUsdFromInstrumentId(instrumentId);
  if (strike == null) return null;

  final qty = order.quantity;
  if (qty == null || qty <= 0) return null;

  final sideRaw = order.side?.toLowerCase().trim();
  final side = switch (sideRaw) {
    'buy' || 'sell' => sideRaw!,
    _ => null,
  };
  if (side == null) return null;

  final premium = dlcPremiumPerContractSatoshisFromCoordinatorRaw(order.price);
  if (premium == null) return null;

  final role = inferDlcOrderMatchRole(order) ?? 'taker';

  return DlcOptionPayoutSimulationRequest(
    side: side,
    role: role,
    optionRight: right == DlcOptionType.call ? 'C' : 'P',
    numContracts: qty,
    strike: strike,
    premiumPerContractSats: premium,
    outcomePrice: outcomePriceUsd,
    premiumPaidUpfront: true,
    networkFeeSats: (order.networkFeeSat ?? 0).round(),
  );
}
