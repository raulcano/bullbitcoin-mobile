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
  String? lastErrorReason,
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
    lastErrorReason: lastErrorReason,
    lastErrorMessage: null,
    oracleOutcomeValue: null,
    fundingTxid: null,
    closingTxid: null,
    refundTxid: null,
  );
}

DlcOrderSummary _orderWithTxids({
  required bool isMaker,
  required String side,
}) {
  return _order(
    status: 'filled',
    dlcId: 'dlc-1',
    dlcStatus: 'cet_closed',
    matchRole: isMaker ? 'maker' : 'taker',
    isMaker: isMaker,
  ).copyWith(
    side: side,
    fundingTxid: 'fund-tx',
    closingTxid: 'close-tx',
    refundTxid: 'refund-tx',
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

    test('filled + funding_broadcasted dlcStatus is live', () {
      expect(
        isDlcLiveOrder(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'funding_broadcasted',
          ),
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

  group('formatDlcStatusLabel', () {
    test('signed reads as funding broadcast pending', () {
      expect(
        formatDlcStatusLabel(
          _order(status: 'filled', dlcId: 'dlc-1', dlcStatus: 'signed'),
        ),
        'Funding broadcast pending',
      );
    });

    test('signed with funding_broadcast_failed reads as failed', () {
      expect(
        formatDlcStatusLabel(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'signed',
            lastErrorReason: 'funding_broadcast_failed',
          ),
        ),
        'Funding broadcast failed',
      );
    });

    test('funding_broadcasted explains maturity is next', () {
      expect(
        formatDlcStatusLabel(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'funding_broadcasted',
          ),
        ),
        'Funding broadcasted, awaiting oracle maturity',
      );
    });
  });

  group('orderShowsFundingTxExplorerLink', () {
    test('true for funding_broadcasted with txid', () {
      expect(
        orderShowsFundingTxExplorerLink(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'funding_broadcasted',
          ).copyWith(fundingTxid: 'abc123'),
        ),
        isTrue,
      );
    });

    test('false without funding txid', () {
      expect(
        orderShowsFundingTxExplorerLink(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'funding_broadcasted',
          ),
        ),
        isFalse,
      );
    });

    test('false for unrelated dlc status', () {
      expect(
        orderShowsFundingTxExplorerLink(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'attested',
          ).copyWith(fundingTxid: 'abc123'),
        ),
        isFalse,
      );
    });
  });

  group('dlcFundingTxMempoolExplorerUrl', () {
    test('uses testnet path on testnet', () {
      expect(
        dlcFundingTxMempoolExplorerUrl(
          fundingTxid: 'abc123',
          isTestnet: true,
        ),
        'https://mempool.space/testnet/tx/abc123',
      );
    });

    test('uses mainnet path on mainnet', () {
      expect(
        dlcFundingTxMempoolExplorerUrl(
          fundingTxid: 'abc123',
          isTestnet: false,
        ),
        'https://mempool.space/tx/abc123',
      );
    });
  });

  group('orderShowsSettlementTxExplorerLink', () {
    test('true for closed order with closing txid', () {
      expect(
        orderShowsSettlementTxExplorerLink(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'cet_closed',
          ).copyWith(closingTxid: 'close-tx'),
        ),
        isTrue,
      );
    });

    test('true for closed order with refund txid', () {
      expect(
        orderShowsSettlementTxExplorerLink(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'refund_closed',
          ).copyWith(refundTxid: 'refund-tx'),
        ),
        isTrue,
      );
    });

    test('false for live order with closing txid', () {
      expect(
        orderShowsSettlementTxExplorerLink(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'funding_broadcasted',
          ).copyWith(closingTxid: 'close-tx'),
        ),
        isFalse,
      );
    });
  });

  group('dlcOrderSettlementTxExplorerLinks', () {
    test('returns settlement and refund links for closed order', () {
      final links = dlcOrderSettlementTxExplorerLinks(
        _order(
          status: 'filled',
          dlcId: 'dlc-1',
          dlcStatus: 'cet_closed',
        ).copyWith(closingTxid: 'close-tx', refundTxid: 'refund-tx'),
        isTestnet: true,
      );
      expect(links, hasLength(2));
      expect(links[0].label, 'Settlement TX');
      expect(links[0].url, 'https://mempool.space/testnet/tx/close-tx');
      expect(links[1].label, 'Refund TX');
      expect(links[1].url, 'https://mempool.space/testnet/tx/refund-tx');
    });
  });

  group('dlcOrderInfoMempoolTxExplorerLinks', () {
    test('maker and taker see identical info-dialog links', () {
      final makerLinks = dlcOrderInfoMempoolTxExplorerLinks(
        _orderWithTxids(isMaker: true, side: 'sell'),
        isTestnet: true,
      );
      final takerLinks = dlcOrderInfoMempoolTxExplorerLinks(
        _orderWithTxids(isMaker: false, side: 'buy'),
        isTestnet: true,
      );
      expect(
        makerLinks.map((link) => (link.label, link.url)).toList(),
        takerLinks.map((link) => (link.label, link.url)).toList(),
      );
      expect(makerLinks.map((link) => link.label), [
        'Funding TX',
        'Settlement TX',
        'Refund TX',
      ]);
    });
  });

  group('dlcOrderMempoolTxExplorerLinks', () {
    test('maker and taker see identical live funding links', () {
      final makerLinks = dlcOrderMempoolTxExplorerLinks(
        _order(
          status: 'filled',
          dlcId: 'dlc-1',
          dlcStatus: 'funding_broadcasted',
          matchRole: 'maker',
          isMaker: true,
        ).copyWith(fundingTxid: 'fund-tx', side: 'sell'),
        isTestnet: false,
        includeFunding: true,
      );
      final takerLinks = dlcOrderMempoolTxExplorerLinks(
        _order(
          status: 'filled',
          dlcId: 'dlc-1',
          dlcStatus: 'funding_broadcasted',
          matchRole: 'taker',
          isMaker: false,
        ).copyWith(fundingTxid: 'fund-tx', side: 'buy'),
        isTestnet: false,
        includeFunding: true,
      );
      expect(
        makerLinks.map((link) => (link.label, link.url)).toList(),
        takerLinks.map((link) => (link.label, link.url)).toList(),
      );
    });

    test('maker and taker see identical closed-card settlement links', () {
      final makerLinks = dlcOrderMempoolTxExplorerLinks(
        _orderWithTxids(isMaker: true, side: 'sell'),
        isTestnet: false,
        includeSettlement: true,
      );
      final takerLinks = dlcOrderMempoolTxExplorerLinks(
        _orderWithTxids(isMaker: false, side: 'buy'),
        isTestnet: false,
        includeSettlement: true,
      );
      expect(
        makerLinks.map((link) => (link.label, link.url)).toList(),
        takerLinks.map((link) => (link.label, link.url)).toList(),
      );
    });

    test('includes funding tx for closed order in info dialog mode', () {
      final links = dlcOrderMempoolTxExplorerLinks(
        _order(
          status: 'filled',
          dlcId: 'dlc-1',
          dlcStatus: 'cet_closed',
        ).copyWith(fundingTxid: 'fund-tx'),
        isTestnet: false,
        includeFunding: true,
        fundingLivePhaseOnly: false,
      );
      expect(links, hasLength(1));
      expect(links.first.label, 'Funding TX');
      expect(links.first.url, 'https://mempool.space/tx/fund-tx');
    });

    test('excludes funding tx for closed order on live card mode', () {
      final links = dlcOrderMempoolTxExplorerLinks(
        _order(
          status: 'filled',
          dlcId: 'dlc-1',
          dlcStatus: 'cet_closed',
        ).copyWith(fundingTxid: 'fund-tx'),
        isTestnet: false,
        includeFunding: true,
      );
      expect(links, isEmpty);
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
