import 'package:bb_mobile/features/dlc/domain/dlc_dlc_detail_sync_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_in_flight.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_utils.dart';
import 'package:flutter_test/flutter_test.dart';

DlcOrderSummary _order({
  String orderId = 'o1',
  String status = 'open',
  String? dlcId,
  String? dlcStatus,
  String? fundingTxid,
  String? closingTxid,
  bool pendingMatchAccept = false,
  DlcOrderInFlightPhase? inFlightPhase,
}) {
  return DlcOrderSummary(
    orderId: orderId,
    dlcId: dlcId,
    status: status,
    pendingMatchAccept: pendingMatchAccept,
    inFlightPhase: inFlightPhase,
    matchedOrderId: null,
    matchedDlcId: null,
    isMaker: null,
    matchRole: null,
    signRequired: null,
    dlcStatus: dlcStatus,
    settlementType: null,
    confirmationStatus: null,
    instrumentId: 'BTC-TEST-C',
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
    closingTxid: closingTxid,
    refundTxid: null,
  );
}

void main() {
  group('orderShouldFetchDlcDetail', () {
    test('open resting order without dlc id does not fetch', () {
      expect(
        orderShouldFetchDlcDetail(_order(status: 'open'), forceRefresh: false),
        isFalse,
      );
    });

    test('live filled order fetches', () {
      expect(
        orderShouldFetchDlcDetail(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'signed',
          ),
          forceRefresh: false,
        ),
        isTrue,
      );
    });

    test('closed settled order with txids does not fetch', () {
      expect(
        orderShouldFetchDlcDetail(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'cet_closed',
            closingTxid: 'abc',
          ),
          forceRefresh: false,
        ),
        isFalse,
      );
    });

    test('closed order without settlement snapshot fetches once', () {
      expect(
        orderShouldFetchDlcDetail(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'cet_closed',
          ),
          forceRefresh: false,
        ),
        isTrue,
      );
    });
  });

  group('coordinatorOrderJsonSkipsDlcDetailFetch', () {
    test('skips terminal list row with settlement txids', () {
      expect(
        coordinatorOrderJsonSkipsDlcDetailFetch({
          'order_id': 'o1',
          'status': 'filled',
          'dlc_id': 'dlc-1',
          'dlc_status': 'cet_closed',
          'closing_txid': 'tx',
        }),
        isTrue,
      );
    });

    test('does not skip active filled row', () {
      expect(
        coordinatorOrderJsonSkipsDlcDetailFetch({
          'order_id': 'o1',
          'status': 'filled',
          'dlc_id': 'dlc-1',
          'dlc_status': 'signed',
        }),
        isFalse,
      );
    });
  });

  group('orderNeedsBackgroundStatusPoll', () {
    test('closed order does not poll', () {
      expect(
        orderNeedsBackgroundStatusPoll(
          _order(
            status: 'filled',
            dlcId: 'dlc-1',
            dlcStatus: 'cet_closed',
            closingTxid: 'x',
          ),
        ),
        isFalse,
      );
    });

    test('open order polls', () {
      expect(
        orderNeedsBackgroundStatusPoll(_order(status: 'open')),
        isTrue,
      );
    });
  });

  group('mergeListOrderWithDlcEnrichment', () {
    test('list status and dlc_status win over stale cache', () {
      final list = _order(
        status: 'filled',
        dlcId: 'dlc-1',
        dlcStatus: 'cet_closed',
        closingTxid: 'close-tx',
      );
      final cached = _order(
        status: 'filled',
        dlcId: 'dlc-1',
        dlcStatus: 'attested',
      ).copyWith(partnerFeeSat: 500);
      final merged = mergeListOrderWithDlcEnrichment(
        list: list,
        enriched: cached,
      );
      expect(merged.dlcStatus, 'cet_closed');
      expect(merged.closingTxid, 'close-tx');
      expect(merged.partnerFeeSat, 500);
    });

    test('fills economics from cache when list omits them', () {
      final list = _order(
        status: 'filled',
        dlcId: 'dlc-1',
        dlcStatus: 'cet_closed',
        closingTxid: 'close-tx',
      );
      final enriched = list.copyWith(
        sideCollateralSat: 1_000_000,
        partnerFeeSat: 250,
      );
      final merged = mergeListOrderWithDlcEnrichment(
        list: list,
        enriched: enriched,
      );
      expect(merged.sideCollateralSat, 1_000_000);
      expect(merged.partnerFeeSat, 250);
    });
  });

  group('listDlcSnapshotAheadOfCached', () {
    test('true when list dlc_status advanced', () {
      expect(
        listDlcSnapshotAheadOfCached(
          list: _order(
            dlcId: 'dlc-1',
            dlcStatus: 'cet_closed',
            closingTxid: 'x',
          ),
          cached: _order(dlcId: 'dlc-1', dlcStatus: 'attested'),
        ),
        isTrue,
      );
    });

    test('false when snapshots match', () {
      final row = _order(
        dlcId: 'dlc-1',
        dlcStatus: 'signed',
        fundingTxid: 'fund',
      );
      expect(
        listDlcSnapshotAheadOfCached(list: row, cached: row),
        isFalse,
      );
    });
  });

  group('isDlcDetailCacheFresh', () {
    test('live cache expires after ttl', () {
      final order = _order(
        status: 'filled',
        dlcId: 'dlc-1',
        dlcStatus: 'signed',
      );
      final now = DateTime.utc(2026, 1, 1, 12, 0, 0);
      expect(
        isDlcDetailCacheFresh(
          fetchedAt: now.subtract(const Duration(seconds: 20)),
          order: order,
          now: now,
        ),
        isTrue,
      );
      expect(
        isDlcDetailCacheFresh(
          fetchedAt: now.subtract(const Duration(seconds: 45)),
          order: order,
          now: now,
        ),
        isFalse,
      );
    });
  });
}
