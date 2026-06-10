import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_wallet_pnl_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dlcWalletPnlSatsFromCoordinatorPayload', () {
    test('reads wallet_pnl_sats from payload', () {
      expect(
        dlcWalletPnlSatsFromCoordinatorPayload({'wallet_pnl_sats': 42}),
        42,
      );
    });
  });

  group('dlcOptionPayoutSimulationRequestForOrder', () {
    test('builds request for a live CALL buy order', () {
      final req = dlcOptionPayoutSimulationRequestForOrder(
        const DlcOrderSummary(
          orderId: 'o1',
          dlcId: 'd1',
          status: 'filled',
          pendingMatchAccept: false,
          isMaker: false,
          matchRole: 'taker',
          signRequired: null,
          dlcStatus: 'signed',
          settlementType: null,
          confirmationStatus: null,
          instrumentId: 'BTC-20260618-95000-C',
          side: 'buy',
          quantity: 2,
          price: 50000,
          createdAt: null,
          sideCollateralSat: null,
          partnerFeeSat: null,
          networkFeeSat: 100,
          lastErrorReason: null,
          lastErrorMessage: null,
          oracleOutcomeValue: null,
          fundingTxid: null,
          closingTxid: null,
          refundTxid: null,
        ),
        outcomePriceUsd: 100_000,
      );
      expect(req, isNotNull);
      expect(req!.side, 'buy');
      expect(req.role, 'taker');
      expect(req.optionRight, 'C');
      expect(req.strike, 95000);
      expect(req.numContracts, 2);
      expect(req.premiumPerContractSats, 50000);
      expect(req.outcomePrice, 100_000);
    });
  });
}
