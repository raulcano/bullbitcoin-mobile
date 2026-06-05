import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_wallet_utxo_projection_utils.dart';
import 'package:flutter_test/flutter_test.dart';

DlcOrderSummary _order({
  required String orderId,
  String? fundingTxid,
  String? dlcStatus,
}) {
  return DlcOrderSummary(
    orderId: orderId,
    dlcId: 'dlc-$orderId',
    status: 'filled',
    pendingMatchAccept: false,
    matchedOrderId: null,
    matchedDlcId: null,
    isMaker: true,
    matchRole: 'maker',
    signRequired: false,
    dlcStatus: dlcStatus,
    settlementType: null,
    confirmationStatus: null,
    instrumentId: 'BTC-20260618-95000-C',
    side: 'buy',
    quantity: 1,
    price: 1000,
    createdAt: null,
    sideCollateralSat: null,
    partnerFeeSat: null,
    networkFeeSat: null,
    lastErrorReason: null,
    lastErrorMessage: null,
    oracleOutcomeValue: null,
    fundingTxid: fundingTxid,
    closingTxid: null,
    refundTxid: null,
  );
}

void main() {
  group('dlcCoordinatorUtxoProjectionKind', () {
    test('detects first funding txid', () {
      expect(
        dlcCoordinatorUtxoProjectionKind(
          current: _order(orderId: 'o1', fundingTxid: 'abc'),
          previous: _order(orderId: 'o1'),
        ),
        DlcCoordinatorUtxoProjectionKind.fundingBroadcast,
      );
    });

    test('detects funding_broadcasted status transition', () {
      expect(
        dlcCoordinatorUtxoProjectionKind(
          current: _order(orderId: 'o1', dlcStatus: 'funding_broadcasted'),
          previous: _order(orderId: 'o1', dlcStatus: 'signed'),
        ),
        DlcCoordinatorUtxoProjectionKind.fundingBroadcast,
      );
    });

    test('detects funding_broadcasted on first observed snapshot', () {
      expect(
        dlcCoordinatorUtxoProjectionKind(
          current: _order(orderId: 'o1', dlcStatus: 'funding_broadcasted'),
          previous: null,
        ),
        DlcCoordinatorUtxoProjectionKind.fundingBroadcast,
      );
    });

    test('detects settlement broadcast status transition', () {
      expect(
        dlcCoordinatorUtxoProjectionKind(
          current: _order(orderId: 'o1', dlcStatus: 'cet_broadcasted'),
          previous: _order(orderId: 'o1', dlcStatus: 'signed'),
        ),
        DlcCoordinatorUtxoProjectionKind.settlementBroadcast,
      );
    });

    test('ignores unchanged settlement broadcast status', () {
      expect(
        dlcCoordinatorUtxoProjectionKind(
          current: _order(orderId: 'o1', dlcStatus: 'cet_broadcasted'),
          previous: _order(orderId: 'o1', dlcStatus: 'cet_broadcasted'),
        ),
        isNull,
      );
    });
  });

  group('dlcOrdersRequireUtxoSyncAfterProjection', () {
    test('true when any order crosses a milestone', () {
      final previous = [_order(orderId: 'o1', dlcStatus: 'signed')];
      final current = [_order(orderId: 'o1', dlcStatus: 'refund_broadcasted')];
      expect(
        dlcOrdersRequireUtxoSyncAfterProjection(
          current: current,
          previous: previous,
        ),
        isTrue,
      );
    });
  });
}
