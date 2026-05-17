import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_utils.dart';
import 'package:flutter_test/flutter_test.dart';

DlcOrderSummary _order({
  String status = 'open',
  String? dlcStatus,
  String? dlcId,
  bool pendingMatchAccept = false,
  String? matchRole,
  bool? isMaker,
  String? matchedOrderId,
}) {
  return DlcOrderSummary(
    orderId: 'order-1',
    dlcId: dlcId,
    status: status,
    pendingMatchAccept: pendingMatchAccept,
    matchedOrderId: matchedOrderId,
    matchedDlcId: null,
    isMaker: isMaker,
    matchRole: matchRole,
    signRequired: null,
    dlcStatus: dlcStatus,
    settlementType: null,
    confirmationStatus: null,
    instrumentId: null,
    side: null,
    quantity: null,
    price: null,
    createdAt: null,
    sideCollateralSat: null,
    partnerFeeSat: null,
    networkFeeSat: null,
    lastErrorReason: null,
    lastErrorMessage: null,
    oracleOutcomeValue: null,
    fundingTxid: null,
    closingTxid: null,
    refundTxid: null,
  );
}

void main() {
  group('dlcPremiumPerContractSatoshisFromCoordinatorRaw', () {
    test('satoshis pass through as rounded integer', () {
      expect(dlcPremiumPerContractSatoshisFromCoordinatorRaw(50300), 50300);
      expect(dlcPremiumPerContractSatoshisFromCoordinatorRaw(50300.2), 50300);
    });

    test('BTC fraction maps to satoshis', () {
      expect(dlcPremiumPerContractSatoshisFromCoordinatorRaw(0.000503), 50300);
    });

    test('null and negative return null', () {
      expect(dlcPremiumPerContractSatoshisFromCoordinatorRaw(null), isNull);
      expect(dlcPremiumPerContractSatoshisFromCoordinatorRaw(-1), isNull);
    });

    test('zero maps to zero', () {
      expect(dlcPremiumPerContractSatoshisFromCoordinatorRaw(0), 0);
    });
  });

  group('dlcOrderbookPremiumPerFullContractSatoshis', () {
    test('divides line premium by row quantity', () {
      expect(
        dlcOrderbookPremiumPerFullContractSatoshis({
          'price': 503000,
          'quantity': 10,
        }),
        50300,
      );
      expect(
        dlcOrderbookPremiumPerFullContractSatoshis({
          'price': 50300,
          'quantity': 0.01,
        }),
        5030000,
      );
    });

    test('falls back to raw when quantity missing or invalid', () {
      expect(
        dlcOrderbookPremiumPerFullContractSatoshis({'price': 5030000}),
        5030000,
      );
    });
  });

  group('dlcFormatGroupedSatoshis', () {
    test('groups thousands with commas', () {
      expect(dlcFormatGroupedSatoshis(50300), '50,300');
      expect(dlcFormatGroupedSatoshis(5030000), '5,030,000');
      expect(dlcFormatGroupedSatoshis(1000000), '1,000,000');
    });

    test('null maps to dash', () {
      expect(dlcFormatGroupedSatoshis(null), '-');
    });
  });

  group('isDlcOpenOrder', () {
    test('open and pending_accept on order.status', () {
      expect(isDlcOpenOrder(_order(status: 'open')), true);
      expect(isDlcOpenOrder(_order(status: 'pending_accept')), true);
      expect(
        isDlcOpenOrder(_order(status: 'filled', pendingMatchAccept: true)),
        true,
      );
    });

    test('filled with signed dlc is not open', () {
      expect(
        isDlcOpenOrder(
          _order(status: 'filled', dlcId: 'dlc-1', dlcStatus: 'signed'),
        ),
        false,
      );
    });
  });

  group('isDlcClosedOrder', () {
    test('terminal order.status values', () {
      expect(isDlcClosedOrder(_order(status: 'cancelled')), true);
      expect(isDlcClosedOrder(_order(status: 'expired')), true);
      expect(isDlcClosedOrder(_order(status: 'rejected')), true);
    });

    test('terminal dlcStatus values', () {
      expect(
        isDlcClosedOrder(
          _order(status: 'filled', dlcId: 'dlc-1', dlcStatus: 'terminated'),
        ),
        true,
      );
      expect(
        isDlcClosedOrder(
          _order(status: 'filled', dlcId: 'dlc-1', dlcStatus: 'cet_closed'),
        ),
        true,
      );
      expect(
        isDlcClosedOrder(
          _order(status: 'filled', dlcId: 'dlc-1', dlcStatus: 'refund_closed'),
        ),
        true,
      );
    });
  });

  group('isDlcLiveOrder', () {
    test('filled + signed dlcStatus is live (funding broadcast phase)', () {
      expect(
        isDlcLiveOrder(
          _order(status: 'filled', dlcId: 'dlc-1', dlcStatus: 'signed'),
        ),
        true,
      );
    });

    test('order.status signed without dlcStatus is not live', () {
      expect(isDlcLiveOrder(_order(status: 'signed', dlcId: 'dlc-1')), false);
    });

    test('filled + attested dlcStatus is live', () {
      expect(
        isDlcLiveOrder(
          _order(status: 'filled', dlcId: 'dlc-1', dlcStatus: 'attested'),
        ),
        true,
      );
    });

    test('filled + terminated dlcStatus is closed not live', () {
      final order = _order(
        status: 'filled',
        dlcId: 'dlc-1',
        dlcStatus: 'terminated',
      );
      expect(isDlcClosedOrder(order), true);
      expect(isDlcLiveOrder(order), false);
    });

    test('open orders are not live', () {
      expect(isDlcLiveOrder(_order(status: 'open')), false);
    });

    test('buckets are mutually exclusive for filled signed', () {
      final order = _order(
        status: 'filled',
        dlcId: 'dlc-1',
        dlcStatus: 'signed',
      );
      expect(isDlcOpenOrder(order), false);
      expect(isDlcClosedOrder(order), false);
      expect(isDlcLiveOrder(order), true);
    });
  });

  group('formatDlcOrderRole', () {
    test('uses match_role from coordinator', () {
      expect(formatDlcOrderRole(_order(matchRole: 'taker')), 'Taker');
    });

    test('open resting order without match is Maker', () {
      expect(formatDlcOrderRole(_order(status: 'open')), 'Maker');
    });

    test('pending_match_accept marks Taker', () {
      expect(
        formatDlcOrderRole(
          _order(
            status: 'pending_accept',
            pendingMatchAccept: true,
            matchedOrderId: 'other',
          ),
        ),
        'Taker',
      );
    });

    test('pending_accept without taker flag is Maker', () {
      expect(
        formatDlcOrderRole(
          _order(
            status: 'pending_accept',
            matchedOrderId: 'other',
          ),
        ),
        'Maker',
      );
    });

    test('filled order uses is_maker when match_role missing', () {
      expect(formatDlcOrderRole(_order(status: 'filled', isMaker: false)), 'Taker');
    });
  });
}
