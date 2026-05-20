import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_in_flight.dart';
import 'package:flutter_test/flutter_test.dart';

DlcOrderSummary _order({
  String orderId = 'order-1',
  String status = 'open',
  bool pendingMatchAccept = false,
  bool? isMaker,
  String? matchRole,
  bool? signRequired,
  String? dlcStatus,
  DlcOrderInFlightPhase? inFlightPhase,
}) {
  return DlcOrderSummary(
    orderId: orderId,
    dlcId: 'dlc-1',
    status: status,
    pendingMatchAccept: pendingMatchAccept,
    inFlightPhase: inFlightPhase,
    matchedOrderId: null,
    matchedDlcId: null,
    isMaker: isMaker,
    matchRole: matchRole,
    signRequired: signRequired,
    dlcStatus: dlcStatus,
    settlementType: null,
    confirmationStatus: null,
    instrumentId: 'inst',
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
    fundingTxid: null,
    closingTxid: null,
    refundTxid: null,
  );
}

void main() {
  group('orderShowsInOpenSection / orderShowsInLiveSection', () {
    test('creating placeholder appears in open', () {
      final order = _order(
        orderId: '${dlcLocalPendingOrderIdPrefix}1',
        status: 'open',
        inFlightPhase: DlcOrderInFlightPhase.creatingOnCoordinator,
      );
      expect(orderShowsInOpenSection(order), isTrue);
      expect(orderShowsInLiveSection(order), isFalse);
    });

    test('matched taker in-flight appears in live', () {
      final order = _order(
        status: 'pending_accept',
        pendingMatchAccept: true,
        matchRole: 'taker',
        inFlightPhase: DlcOrderInFlightPhase.takerSigningAccept,
      );
      expect(orderShowsInLiveSection(order), isTrue);
      expect(orderShowsInOpenSection(order), isFalse);
    });

    test('filled with stale pending flag is live via coordinator status', () {
      final order = _order(
        status: 'filled',
        pendingMatchAccept: true,
        matchRole: 'taker',
        dlcStatus: 'accepted',
      );
      expect(resolveOrderInFlightPhase(order), isNull);
      expect(orderShowsInOpenSection(order), isFalse);
    });

    test('maker filled awaiting taker is not counted as open', () {
      final order = _order(
        status: 'filled',
        isMaker: true,
        matchRole: 'maker',
        dlcStatus: 'accepted',
      );
      expect(orderShowsInLiveSection(order), isTrue);
      expect(orderShowsInOpenSection(order), isFalse);
      expect(dlcOpenOrdersCount([order]), 0);
      expect(dlcLiveOrdersCount([order]), 1);
    });

    test('dlcOpenOrdersCount matches open section only', () {
      final open = _order(
        orderId: '${dlcLocalPendingOrderIdPrefix}2',
        status: 'open',
        inFlightPhase: DlcOrderInFlightPhase.creatingOnCoordinator,
      );
      final live = _order(
        status: 'pending_accept',
        pendingMatchAccept: true,
        inFlightPhase: DlcOrderInFlightPhase.takerSigningAccept,
      );
      expect(dlcOpenOrdersCount([open, live]), 1);
      expect(dlcLiveOrdersCount([open, live]), 1);
    });
  });

  group('resolveOrderInFlightPhase', () {
    test('maker awaiting taker accept', () {
      final order = _order(
        status: 'filled',
        isMaker: true,
        matchRole: 'maker',
        dlcStatus: 'accepted',
      );
      expect(
        resolveOrderInFlightPhase(order),
        DlcOrderInFlightPhase.matchedAwaitingTakerAccept,
      );
    });

    test('maker signing when sign_required', () {
      final order = _order(
        status: 'filled',
        isMaker: true,
        matchRole: 'maker',
        signRequired: true,
        dlcStatus: 'accepted',
      );
      expect(
        resolveOrderInFlightPhase(order),
        DlcOrderInFlightPhase.makerSigningDlc,
      );
    });

    test('taker awaiting maker sign after accept', () {
      final order = _order(
        status: 'filled',
        isMaker: false,
        matchRole: 'taker',
        pendingMatchAccept: false,
        signRequired: true,
        dlcStatus: 'accepted',
      );
      expect(isTakerAwaitingMakerSign(order), isTrue);
      expect(
        resolveOrderInFlightPhase(order),
        DlcOrderInFlightPhase.makerSigningDlc,
      );
    });

    test('taker keeps maker-signing hourglass before sign_required', () {
      final order = _order(
        status: 'filled',
        isMaker: false,
        matchRole: 'taker',
        pendingMatchAccept: false,
        dlcStatus: 'accepted',
      ).copyWith(signRequired: null, matchedOrderId: 'maker-order-1');
      expect(isTakerAwaitingMakerSign(order), isTrue);
      expect(
        resolveOrderInFlightPhase(order),
        DlcOrderInFlightPhase.makerSigningDlc,
      );
    });
  });

  group('optimisticTrimOrderbookForMatch', () {
    test('buy consumes ask liquidity at price', () {
      final draft = DlcOrderDraft(
        instrumentId: 'inst',
        side: DlcOrderSide.buy,
        quantity: 2,
        price: 1000,
        strikePrice: null,
        fundingPubkeyHex: '',
      );
      final result = optimisticTrimOrderbookForMatch(
        bids: const [],
        asks: [
          {'price': 2000, 'quantity': 2},
        ],
        draft: draft,
      );
      expect(result.asks, isEmpty);
    });
  });

  group('mergeCoordinatorOrdersWithLocal', () {
    test('keeps local-pending when coordinator list is empty', () {
      final pending = _order(
        orderId: '${dlcLocalPendingOrderIdPrefix}1',
        inFlightPhase: DlcOrderInFlightPhase.creatingOnCoordinator,
      );
      final merged = mergeCoordinatorOrdersWithLocal(
        coordinatorOrders: const [],
        currentOrders: [pending],
      );
      expect(merged, hasLength(1));
      expect(merged.first.orderId, pending.orderId);
    });

    test('coordinator list wins when order id is present', () {
      final local = _order(orderId: 'order-1', status: 'open').copyWith(price: 500);
      final remote =
          _order(orderId: 'order-1', status: 'open').copyWith(price: 1000);
      final merged = mergeCoordinatorOrdersWithLocal(
        coordinatorOrders: [remote],
        currentOrders: [local],
      );
      expect(merged, hasLength(1));
      expect(merged.first.price, 1000);
    });

    test('keeps recently created order missing from coordinator', () {
      final local = _order(
        orderId: 'order-new',
        status: 'open',
        inFlightPhase: DlcOrderInFlightPhase.creatingOnCoordinator,
      ).copyWith(createdAt: DateTime.now().toUtc());
      final merged = mergeCoordinatorOrdersWithLocal(
        coordinatorOrders: const [],
        currentOrders: [local],
      );
      expect(merged.map((o) => o.orderId), contains('order-new'));
    });
  });

  group('dlcOrderShowsInfoDuringInFlight', () {
    test('open create shows hourglass only', () {
      expect(
        dlcOrderShowsInfoDuringInFlight(
          DlcOrderInFlightPhase.creatingOnCoordinator,
        ),
        isFalse,
      );
    });

    test('matched flow shows info and hourglass', () {
      expect(
        dlcOrderShowsInfoDuringInFlight(
          DlcOrderInFlightPhase.takerSigningAccept,
        ),
        isTrue,
      );
    });
  });
}
