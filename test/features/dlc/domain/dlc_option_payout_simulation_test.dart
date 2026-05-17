import 'package:bb_mobile/features/dlc/domain/dlc_option_payout_simulation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DlcOptionPayoutSimulationResult', () {
    test('fromJson parses wallet economics and chart payloads', () {
      final json = <String, dynamic>{
        'rounded_pnl_sats': -100,
        'canonical_pnl_sats': -95,
        'wallet_posted_collateral_sats': 50_000_000,
        'premium_paid_upfront_sats': 0,
        'premium_received_upfront_sats': 50_300,
        'premium_embedded_in_dlc_sats': 1_000,
        'wallet_rounded_settlement_payout_sats': 49_000_000,
        'wallet_canonical_payout_sats': 49_000_050,
        'network_fee_sats': 1200,
        'wallet_fee_sats': 300,
        'total_fee_sats': 1500,
        'rounding_delta_sats': -50,
        'intervals': [
          <String, dynamic>{
            'index': 0,
            'start': 9000,
            'end': 9999,
            'wallet_payout': 1000,
            'counterparty_payout': 2000,
            'compressed_digit_count': 1,
          },
        ],
        'canonical_points': [
          <String, dynamic>{
            'x': 9500,
            'wallet_payout': 1100,
            'counterparty_payout': 2100,
          },
        ],
        'outcome_interval': <String, dynamic>{'start': 9900, 'end': 10000},
      };

      final r = DlcOptionPayoutSimulationResult.fromJson(json);

      expect(r.roundedPnlSats, -100);
      expect(r.canonicalPnlSats, -95);
      expect(r.walletPostedCollateralSats, 50_000_000);
      expect(r.premiumReceivedUpfrontSats, 50_300);
      expect(r.premiumEmbeddedInDlcSats, 1000);
      expect(r.walletRoundedSettlementPayoutSats, 49_000_000);
      expect(r.walletCanonicalPayoutSats, 49_000_050);
      expect(r.networkFeeSats, 1200);
      expect(r.walletFeeSats, 300);
      expect(r.totalFeeSats, 1500);
      expect(r.roundingDeltaSats, -50);

      expect(r.intervals, hasLength(1));
      expect(r.intervals.single.walletPayout, 1000);
      expect(r.canonicalPoints, hasLength(1));
      expect(r.canonicalPoints.single.x, 9500);
      expect(r.outcomeInterval?.start, 9900);
      expect(r.outcomeInterval?.end, 10000);
    });
  });

  group('DlcOptionPayoutSimulationRequest', () {
    test('toJson omits wallet_fee_sats and includes role', () {
      const req = DlcOptionPayoutSimulationRequest(
        side: 'buy',
        role: 'taker',
        optionRight: 'P',
        numContracts: 0.5,
        strike: 100_000,
        premiumPerContractSats: 50300,
        outcomePrice: 95_000,
        premiumPaidUpfront: true,
        networkFeeSats: 1200,
        numDigits: 8,
      );

      expect(req.toJson(), {
        'side': 'buy',
        'role': 'taker',
        'option_right': 'P',
        'num_contracts': 0.5,
        'strike': 100000,
        'premium_per_contract_sats': 50300,
        'outcome_price': 95000,
        'premium_paid_upfront': true,
        'network_fee_sats': 1200,
        'num_digits': 8,
      });
    });
  });
}
