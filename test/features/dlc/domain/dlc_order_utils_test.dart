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
    test('only open status counts as open', () {
      expect(isDlcOpenOrder(_order(status: 'open')), true);
      expect(isDlcOpenOrder(_order(status: 'pending_accept')), false);
      expect(
        isDlcOpenOrder(_order(status: 'filled', pendingMatchAccept: true)),
        false,
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
      expect(
        isDlcClosedOrder(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'refund_broadcasted',
          ),
        ),
        true,
      );
      expect(
        isDlcClosedOrder(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'cet_broadcasted',
          ),
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

    test('filled + refund_broadcasted dlcStatus is closed not live', () {
      final order = _order(
        status: 'filled',
        dlcId: 'dlc-1',
        dlcStatus: 'refund_broadcasted',
      );
      expect(isDlcClosedOrder(order), true);
      expect(isDlcLiveOrder(order), false);
    });

    test('open orders are not live', () {
      expect(isDlcLiveOrder(_order(status: 'open')), false);
    });

    test('pending_accept is live not open', () {
      final pending = _order(status: 'pending_accept', dlcId: 'dlc-1');
      expect(isDlcOpenOrder(pending), false);
      expect(isDlcLiveOrder(pending), true);
      expect(isDlcClosedOrder(pending), false);
    });

    test('pending_match_accept flag is live', () {
      final taker = _order(
        status: 'pending_accept',
        pendingMatchAccept: true,
        dlcId: 'dlc-1',
      );
      expect(isDlcLiveOrder(taker), true);
      expect(isDlcOpenOrder(taker), false);
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

  group('dlcOrderbookRowIsOwnWalletOpenOrder', () {
    DlcOrderSummary openSellOrder({
      String orderId = 'mine-1',
      String instrumentId = 'BTC-18MAR26-74100-C',
      double quantity = 2,
      double price = 5000000,
    }) {
      return DlcOrderSummary(
        orderId: orderId,
        dlcId: null,
        status: 'open',
        pendingMatchAccept: false,
        matchedOrderId: null,
        matchedDlcId: null,
        isMaker: null,
        matchRole: null,
        signRequired: null,
        dlcStatus: null,
        settlementType: null,
        confirmationStatus: null,
        instrumentId: instrumentId,
        side: 'sell',
        quantity: quantity,
        price: price,
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

    Map<String, dynamic> askRow({String? orderId, int price = 5000000}) => {
      'price': price,
      'quantity': 2,
      'instrument_id': 'BTC-18MAR26-74100-C',
      if (orderId != null) 'order_id': orderId,
    };

    test('matches sell order on asks side when book is unambiguous', () {
      final row = askRow();
      expect(
        dlcOrderbookRowIsOwnWalletOpenOrder(
          row: row,
          isAskRow: true,
          orders: [openSellOrder()],
          orderbookSideRows: [row],
          selectedInstrumentId: 'BTC-18MAR26-74100-C',
        ),
        isTrue,
      );
    });

    test('does not match buy order on asks side', () {
      final buy = openSellOrder();
      final row = askRow();
      expect(
        dlcOrderbookRowIsOwnWalletOpenOrder(
          row: row,
          isAskRow: true,
          orders: [
            DlcOrderSummary(
              orderId: buy.orderId,
              dlcId: buy.dlcId,
              status: buy.status,
              pendingMatchAccept: buy.pendingMatchAccept,
              matchedOrderId: buy.matchedOrderId,
              matchedDlcId: buy.matchedDlcId,
              isMaker: buy.isMaker,
              matchRole: buy.matchRole,
              signRequired: buy.signRequired,
              dlcStatus: buy.dlcStatus,
              settlementType: buy.settlementType,
              confirmationStatus: buy.confirmationStatus,
              instrumentId: buy.instrumentId,
              side: 'buy',
              quantity: buy.quantity,
              price: buy.price,
              createdAt: buy.createdAt,
              sideCollateralSat: buy.sideCollateralSat,
              partnerFeeSat: buy.partnerFeeSat,
              networkFeeSat: buy.networkFeeSat,
              lastErrorReason: buy.lastErrorReason,
              lastErrorMessage: buy.lastErrorMessage,
              oracleOutcomeValue: buy.oracleOutcomeValue,
              fundingTxid: buy.fundingTxid,
              closingTxid: buy.closingTxid,
              refundTxid: buy.refundTxid,
            ),
          ],
          orderbookSideRows: [row],
          selectedInstrumentId: 'BTC-18MAR26-74100-C',
        ),
        isFalse,
      );
    });

    test('does not underline when another wallet has identical resting order', () {
      DlcOrderSummary openBuyOrder({
        String orderId = 'mine-1',
        double quantity = 0.01,
        double price = 5030000,
      }) {
        return DlcOrderSummary(
          orderId: orderId,
          dlcId: null,
          status: 'open',
          pendingMatchAccept: false,
          matchedOrderId: null,
          matchedDlcId: null,
          isMaker: null,
          matchRole: null,
          signRequired: null,
          dlcStatus: null,
          settlementType: null,
          confirmationStatus: null,
          instrumentId: 'BTC-18MAR26-74100-C',
          side: 'buy',
          quantity: quantity,
          price: price,
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

      final rowA = {
        'price': 50300,
        'quantity': 0.01,
        'instrument_id': 'BTC-18MAR26-74100-C',
      };
      final rowB = {
        'price': 50300,
        'quantity': 0.01,
        'instrument_id': 'BTC-18MAR26-74100-C',
      };
      final book = [rowA, rowB];

      expect(
        dlcOrderbookRowIsOwnWalletOpenOrder(
          row: rowA,
          isAskRow: false,
          orders: [openBuyOrder()],
          orderbookSideRows: book,
          selectedInstrumentId: 'BTC-18MAR26-74100-C',
        ),
        isFalse,
      );
      expect(
        dlcOrderbookRowIsOwnWalletOpenOrder(
          row: rowB,
          isAskRow: false,
          orders: [openBuyOrder()],
          orderbookSideRows: book,
          selectedInstrumentId: 'BTC-18MAR26-74100-C',
        ),
        isFalse,
      );
    });

    test('matches when row price is line total divided by quantity', () {
      final row = {
        'price': 10000000,
        'quantity': 2,
        'instrument_id': 'BTC-18MAR26-74100-C',
      };
      expect(
        dlcOrderbookRowIsOwnWalletOpenOrder(
          row: row,
          isAskRow: true,
          orders: [openSellOrder()],
          orderbookSideRows: [row],
          selectedInstrumentId: 'BTC-18MAR26-74100-C',
        ),
        isTrue,
      );
    });

    test('underlines both rows when wallet has two identical resting orders', () {
      final rowA = {
        'price': 50300,
        'quantity': 0.01,
        'instrument_id': 'BTC-18MAR26-74100-C',
      };
      final rowB = {
        'price': 50300,
        'quantity': 0.01,
        'instrument_id': 'BTC-18MAR26-74100-C',
      };
      final orders = [
        openSellOrder(orderId: 'mine-1', quantity: 0.01, price: 5030000),
        openSellOrder(orderId: 'mine-2', quantity: 0.01, price: 5030000),
      ];
      final book = [rowA, rowB];

      expect(
        dlcOrderbookRowIsOwnWalletOpenOrder(
          row: rowA,
          isAskRow: true,
          orders: orders,
          orderbookSideRows: book,
          selectedInstrumentId: 'BTC-18MAR26-74100-C',
        ),
        isTrue,
      );
      expect(
        dlcOrderbookRowIsOwnWalletOpenOrder(
          row: rowB,
          isAskRow: true,
          orders: orders,
          orderbookSideRows: book,
          selectedInstrumentId: 'BTC-18MAR26-74100-C',
        ),
        isTrue,
      );
    });

    test('underlines aggregated row when two own orders sum to row quantity', () {
      final row = {
        'price': 100600,
        'quantity': 0.02,
        'instrument_id': 'BTC-18MAR26-74100-C',
      };
      final orders = [
        openSellOrder(orderId: 'mine-1', quantity: 0.01, price: 5030000),
        openSellOrder(orderId: 'mine-2', quantity: 0.01, price: 5030000),
      ];

      expect(
        dlcOrderbookRowIsOwnWalletOpenOrder(
          row: row,
          isAskRow: true,
          orders: orders,
          orderbookSideRows: [row],
          selectedInstrumentId: 'BTC-18MAR26-74100-C',
        ),
        isTrue,
      );
    });

    test('matches by order_id when row includes coordinator order id', () {
      final row = askRow(orderId: 'mine-1');
      final other = askRow(orderId: 'other-wallet');
      expect(
        dlcOrderbookRowIsOwnWalletOpenOrder(
          row: row,
          isAskRow: true,
          orders: [openSellOrder(orderId: 'mine-1')],
          orderbookSideRows: [row, other],
          selectedInstrumentId: 'BTC-18MAR26-74100-C',
        ),
        isTrue,
      );
      expect(
        dlcOrderbookRowIsOwnWalletOpenOrder(
          row: other,
          isAskRow: true,
          orders: [openSellOrder(orderId: 'mine-1')],
          orderbookSideRows: [row, other],
          selectedInstrumentId: 'BTC-18MAR26-74100-C',
        ),
        isFalse,
      );
    });
  });

  group('dlcSellerCollateralSats', () {
    test('buy order uses acceptor collateral not buyer premium', () {
      expect(
        dlcSellerCollateralSats(
          json: {
            'side': 'buy',
            'buyer_collateral_sats': 50_300,
            'acceptor_collateral_sats': 100_000_000,
          },
          side: 'buy',
          quantity: 1,
        ),
        100_000_000,
      );
    });

    test('sell order uses offerer collateral', () {
      expect(
        dlcSellerCollateralSats(
          json: {
            'side': 'sell',
            'offerer_collateral_sats': 50_000_000,
            'buyer_collateral_sats': 50_300,
          },
          side: 'sell',
          quantity: 0.5,
        ),
        50_000_000,
      );
    });

    test('derives from quantity when API omits collateral fields', () {
      expect(
        dlcSellerCollateralSats(side: 'buy', quantity: 2),
        2 * dlcSatsPerOptionContract,
      );
    });

    test('ignores buyer collateral when only buyer field is present', () {
      expect(
        dlcSellerCollateralSats(
          json: {'buyer_collateral_sats': 50_300},
          side: 'buy',
          quantity: 1,
        ),
        dlcSatsPerOptionContract,
      );
    });
  });
}
