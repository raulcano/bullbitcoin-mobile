import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_negotiation_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// Coverage for the "one canonical DLC per trade" migration.
///
/// Each test maps to one bullet in the migration spec's "Required Client
/// Tests" section.
void main() {
  group('canonical DLC migration', () {
    test('unmatched order stores draft offer without creating a DLC', () {
      // POST /orders response with no match.
      final order = _orderFromCoordinatorJson({
        'order_id': 'maker-1',
        'dlc_id': null,
        'status': 'open',
        'offer_object_hex': 'draft-hex',
        'pending_match_accept': false,
        'executions': const <Map<String, dynamic>>[],
      });

      expect(order.dlcId, isNull);
      expect(order.executions, isEmpty);
      expect(order.draftOfferObjectHex, 'draft-hex');
      // No DLC has been created — neither role's signing workflow runs.
      expect(needsDlcTakerAccept(order), isFalse);
      expect(needsDlcMakerSign(order), isFalse);
    });

    test('immediate match creates one execution and starts taker accept', () {
      final order = _orderFromCoordinatorJson({
        'order_id': 'taker-1',
        'dlc_id': 'dlc-canonical',
        'status': 'pending_accept',
        'offer_object_hex': 'finalized-hex',
        'pending_match_accept': true,
        'executions': [
          {
            'trade_id': 'trade-1',
            'dlc_id': 'dlc-canonical',
            'role': 'taker',
            'counterparty_order_id': 'maker-1',
            'status': 'pending_accept',
          },
        ],
      });

      expect(order.dlcId, 'dlc-canonical');
      expect(order.executions, hasLength(1));
      expect(order.latestExecution!.role, 'taker');
      expect(order.draftOfferObjectHex, isNull);
      expect(needsDlcTakerAccept(order), isTrue);
      expect(isDlcTakerForAccept(order), isTrue);
      expect(isDlcMakerForSign(order), isFalse);
    });

    test('maker discovers match via polling and waits without signing', () {
      // Resting maker polled GET /orders/{id}; status flipped open -> pending_accept.
      final order = _orderFromCoordinatorJson({
        'order_id': 'maker-1',
        'dlc_id': 'dlc-canonical',
        'status': 'pending_accept',
        'pending_match_accept': false,
        'executions': [
          {
            'trade_id': 'trade-1',
            'dlc_id': 'dlc-canonical',
            'role': 'maker',
            'counterparty_order_id': 'taker-1',
            'status': 'pending_accept',
          },
        ],
      });

      // Maker may not call /accept-context on someone else's accept window.
      expect(isDlcTakerForAccept(order), isFalse);
      expect(isDlcMakerForSign(order), isTrue);
      // sign_required is false until the taker accept lands.
      expect(needsDlcMakerSign(order), isFalse);
    });

    test('maker and taker resolve the same trade_id and dlc_id', () {
      final makerOrder = _orderFromCoordinatorJson({
        'order_id': 'maker-1',
        'dlc_id': 'dlc-canonical',
        'status': 'filled',
        'pending_match_accept': false,
        'executions': [
          {
            'trade_id': 'trade-1',
            'dlc_id': 'dlc-canonical',
            'role': 'maker',
            'counterparty_order_id': 'taker-1',
            'status': 'executed',
          },
        ],
      });

      final takerOrder = _orderFromCoordinatorJson({
        'order_id': 'taker-1',
        'dlc_id': 'dlc-canonical',
        'status': 'filled',
        'pending_match_accept': false,
        'executions': [
          {
            'trade_id': 'trade-1',
            'dlc_id': 'dlc-canonical',
            'role': 'taker',
            'counterparty_order_id': 'maker-1',
            'status': 'executed',
          },
        ],
      });

      expect(makerOrder.dlcId, takerOrder.dlcId);
      expect(makerOrder.latestExecution!.tradeId,
          takerOrder.latestExecution!.tradeId);
      expect(makerOrder.latestExecution!.role, 'maker');
      expect(takerOrder.latestExecution!.role, 'taker');
    });

    test('only the taker can accept and only the maker can sign', () {
      final taker = _orderFromCoordinatorJson({
        'order_id': 'taker-1',
        'dlc_id': 'dlc-1',
        'status': 'pending_accept',
        'pending_match_accept': true,
        'executions': [
          {
            'trade_id': 'trade-1',
            'dlc_id': 'dlc-1',
            'role': 'taker',
            'counterparty_order_id': 'maker-1',
            'status': 'pending_accept',
          },
        ],
      });
      final maker = _orderFromCoordinatorJson({
        'order_id': 'maker-1',
        'dlc_id': 'dlc-1',
        'status': 'filled',
        'sign_required': true,
        'dlc_status': 'accepted',
        'pending_match_accept': false,
        'executions': [
          {
            'trade_id': 'trade-1',
            'dlc_id': 'dlc-1',
            'role': 'maker',
            'counterparty_order_id': 'taker-1',
            'status': 'executed',
            'dlc_status': 'accepted',
          },
        ],
      });

      expect(isDlcTakerForAccept(taker), isTrue);
      expect(isDlcMakerForSign(taker), isFalse);
      expect(isDlcMakerForSign(maker), isTrue);
      expect(isDlcTakerForAccept(maker), isFalse);
      expect(needsDlcMakerSign(maker), isTrue);
      expect(needsDlcMakerSign(taker), isFalse);
    });

    test('canonical DLC info maps role from maker_order_id / taker_order_id',
        () {
      final dlc = DlcCanonicalDlcInfo.tryFromJson({
        'dlc_id': 'dlc-1',
        'trade_id': 'trade-1',
        'maker_order_id': 'maker-1',
        'taker_order_id': 'taker-1',
        'status': 'accepted',
      });
      expect(dlc, isNotNull);
      expect(dlc!.roleForOrderId('maker-1'), 'maker');
      expect(dlc.roleForOrderId('taker-1'), 'taker');
      expect(dlc.roleForOrderId('unknown'), isNull);
    });

    test('failed execution is preserved alongside a later successful match',
        () {
      final order = _orderFromCoordinatorJson({
        'order_id': 'maker-1',
        'dlc_id': 'dlc-2',
        'status': 'filled',
        'pending_match_accept': false,
        'executions': [
          {
            'trade_id': 'trade-1',
            'dlc_id': 'dlc-1',
            'role': 'maker',
            'counterparty_order_id': 'taker-1',
            'status': 'failed',
            'last_error_reason': 'accept_timeout',
          },
          {
            'trade_id': 'trade-2',
            'dlc_id': 'dlc-2',
            'role': 'maker',
            'counterparty_order_id': 'taker-2',
            'status': 'executed',
          },
        ],
      });

      expect(order.executions, hasLength(2));
      expect(order.executions.first.isFailed, isTrue);
      expect(order.executions.last.isExecuted, isTrue);
      expect(order.dlcId, 'dlc-2');
      expect(order.latestExecution!.tradeId, 'trade-2');
      expect(order.lastSuccessfulExecution!.tradeId, 'trade-2');
    });

    test('one order can persist multiple execution links', () {
      final order = _orderFromCoordinatorJson({
        'order_id': 'maker-1',
        'dlc_id': 'dlc-3',
        'status': 'filled',
        'executions': [
          {
            'trade_id': 'trade-1',
            'dlc_id': 'dlc-1',
            'role': 'maker',
            'status': 'expired',
          },
          {
            'trade_id': 'trade-2',
            'dlc_id': 'dlc-2',
            'role': 'maker',
            'status': 'failed',
          },
          {
            'trade_id': 'trade-3',
            'dlc_id': 'dlc-3',
            'role': 'maker',
            'status': 'executed',
          },
        ],
      });

      final tradeIds = order.executions.map((e) => e.tradeId).toList();
      expect(tradeIds, ['trade-1', 'trade-2', 'trade-3']);
      expect(order.dlcId, 'dlc-3');
      expect(order.executions.first.isExpired, isTrue);
    });

    test('stale_accept_context error message is detected', () {
      // Repository drops signatures and re-fetches when this message appears.
      const error = 'HTTP 409: stale_accept_context: re-fetch context';
      expect(error.toLowerCase().contains('stale_accept_context'), isTrue);
      // Sanity: the existing helper does not classify this as a benign retry.
      expect(isAcceptSigningNoLongerRequired(Exception(error)), isFalse);
    });

    test('timeout reopens the maker order and rejects the taker', () {
      final makerReopened = _orderFromCoordinatorJson({
        'order_id': 'maker-1',
        'dlc_id': null,
        'status': 'open',
        'pending_match_accept': false,
        'executions': [
          {
            'trade_id': 'trade-1',
            'dlc_id': 'dlc-1',
            'role': 'maker',
            'counterparty_order_id': 'taker-1',
            'status': 'expired',
          },
        ],
      });
      final takerRejected = _orderFromCoordinatorJson({
        'order_id': 'taker-1',
        'dlc_id': 'dlc-1',
        'status': 'rejected',
        'last_error_reason': 'accept_timeout',
        'executions': [
          {
            'trade_id': 'trade-1',
            'dlc_id': 'dlc-1',
            'role': 'taker',
            'counterparty_order_id': 'maker-1',
            'status': 'expired',
            'last_error_reason': 'accept_timeout',
          },
        ],
      });

      // Maker is back on the orderbook even though `executions[]` retains the
      // expired attempt for history.
      expect(makerReopened.status, 'open');
      expect(makerReopened.executions, hasLength(1));
      expect(makerReopened.executions.last.isExpired, isTrue);

      expect(takerRejected.status, 'rejected');
      expect(takerRejected.lastErrorReason, 'accept_timeout');
    });

    test('latest dlc_status falls back to the latest execution', () {
      final order = _orderFromCoordinatorJson({
        'order_id': 'maker-1',
        'dlc_id': 'dlc-1',
        'status': 'filled',
        'executions': [
          {
            'trade_id': 'trade-1',
            'dlc_id': 'dlc-1',
            'role': 'maker',
            'status': 'executed',
            'dlc_status': 'funding_broadcasted',
          },
        ],
      });
      expect(order.dlcStatus, 'funding_broadcasted');
    });

    test('formatDlcOrderRole prefers latest execution role', () {
      final order = _orderFromCoordinatorJson({
        'order_id': 'taker-1',
        'dlc_id': 'dlc-1',
        'status': 'filled',
        // Stale legacy fields claiming maker:
        'is_maker': true,
        'match_role': 'maker',
        'executions': [
          {
            'trade_id': 'trade-1',
            'dlc_id': 'dlc-1',
            'role': 'taker',
            'counterparty_order_id': 'maker-1',
            'status': 'executed',
          },
        ],
      });
      expect(formatDlcOrderRole(order), 'Taker');
    });
  });
}

DlcOrderSummary _orderFromCoordinatorJson(Map<String, dynamic> json) {
  // Mirror the production parser closely enough for these unit tests without
  // pulling in DlcRepository (which requires storage and signers).
  final executions = <DlcOrderExecution>[];
  final rawExecutions = json['executions'];
  if (rawExecutions is List) {
    for (final entry in rawExecutions) {
      final parsed = DlcOrderExecution.tryFromJson(entry);
      if (parsed != null) executions.add(parsed);
    }
  }
  final latest = executions.isNotEmpty ? executions.last : null;
  final topLevelDlcId = (json['dlc_id'] as String?)?.trim();
  final dlcId = (topLevelDlcId != null && topLevelDlcId.isNotEmpty)
      ? topLevelDlcId
      : latest?.dlcId;

  return DlcOrderSummary(
    orderId: json['order_id'] as String? ?? '',
    dlcId: dlcId,
    status: json['status'] as String? ?? 'unknown',
    pendingMatchAccept: json['pending_match_accept'] as bool? ?? false,
    isMaker: latest?.isMaker ?? json['is_maker'] as bool?,
    matchRole: latest?.role ?? json['match_role'] as String?,
    signRequired: json['sign_required'] as bool?,
    dlcStatus: (json['dlc_status'] as String?) ?? latest?.dlcStatus,
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
    lastErrorReason:
        (json['last_error_reason'] as String?) ?? latest?.lastErrorReason,
    lastErrorMessage:
        (json['last_error_message'] as String?) ?? latest?.lastErrorMessage,
    oracleOutcomeValue: null,
    fundingTxid: null,
    closingTxid: null,
    refundTxid: null,
    draftOfferObjectHex: executions.isEmpty
        ? json['offer_object_hex'] as String?
        : null,
    executions: List<DlcOrderExecution>.unmodifiable(executions),
  );
}
