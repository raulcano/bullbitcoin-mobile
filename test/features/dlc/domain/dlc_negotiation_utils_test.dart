import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_negotiation_utils.dart';
import 'package:flutter_test/flutter_test.dart';

DlcOrderSummary _order({
  String status = 'open',
  String? dlcStatus,
  bool pendingMatchAccept = false,
  bool? signRequired,
  bool? isMaker,
  String? fundingTxid,
  String? dlcId,
}) {
  return DlcOrderSummary(
    orderId: 'order-1',
    dlcId: dlcId,
    status: status,
    pendingMatchAccept: pendingMatchAccept,
    isMaker: isMaker,
    matchRole: isMaker == true ? 'maker' : null,
    signRequired: signRequired,
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
    fundingTxid: fundingTxid,
    closingTxid: null,
    refundTxid: null,
  );
}

void main() {
  group('needsDlcTakerAccept', () {
    test('true when pending_match_accept flag is set', () {
      expect(
        needsDlcTakerAccept(_order(pendingMatchAccept: true)),
        isTrue,
      );
    });

    test('false when coordinator status is filled even if flag is stale', () {
      expect(
        needsDlcTakerAccept(
          _order(
            status: 'filled',
            pendingMatchAccept: true,
            dlcId: 'dlc-1',
          ),
        ),
        isFalse,
      );
    });

    test('true when status is pending_accept', () {
      expect(
        needsDlcTakerAccept(_order(status: 'pending_accept')),
        isTrue,
      );
    });
  });

  group('isDlcTakerForAccept', () {
    test('true when pending_match_accept is set even without match_role', () {
      // Coordinators that have not rolled out canonical-DLC `executions[]`
      // identify the active taker side via `pending_match_accept: true` and
      // may omit `match_role` / `is_maker` while the order is in
      // `pending_accept`. The negotiation worker must still fire the accept
      // flow.
      expect(
        isDlcTakerForAccept(
          _order(status: 'pending_accept', pendingMatchAccept: true),
        ),
        isTrue,
      );
    });

    test('false for the maker side of an active match', () {
      // Maker observes `status: pending_accept` but `pending_match_accept`
      // is false on its own order. Must not trigger /accept-context.
      expect(
        isDlcTakerForAccept(
          _order(
            status: 'pending_accept',
            pendingMatchAccept: false,
            isMaker: true,
          ),
        ),
        isFalse,
      );
    });

    test('true when is_maker == false even with stale match_role', () {
      expect(
        isDlcTakerForAccept(_order(isMaker: false)),
        isTrue,
      );
    });
  });

  group('isDlcMakerForSign', () {
    test('true when sign_required and DLC is accepted (no explicit role)', () {
      // Maker may briefly lack `match_role` / `is_maker` from the coordinator
      // while moving past accept; `sign_required: true` is per-wallet and
      // identifies the maker that owes a /sign-context.
      expect(
        isDlcMakerForSign(
          _order(
            status: 'filled',
            dlcStatus: 'accepted',
            signRequired: true,
            dlcId: 'dlc-1',
          ),
        ),
        isTrue,
      );
    });

    test('false when sign_required is unset', () {
      expect(
        isDlcMakerForSign(
          _order(status: 'filled', dlcStatus: 'accepted', dlcId: 'dlc-1'),
        ),
        isFalse,
      );
    });
  });

  group('needsDlcMakerSign', () {
    test('true for filled maker with accepted DLC and sign_required', () {
      expect(
        needsDlcMakerSign(
          _order(
            status: 'filled',
            dlcStatus: 'accepted',
            signRequired: true,
            isMaker: true,
            dlcId: 'dlc-1',
          ),
        ),
        isTrue,
      );
    });

    test('false after DLC is signed', () {
      expect(
        needsDlcMakerSign(
          _order(
            status: 'filled',
            dlcStatus: 'signed',
            signRequired: true,
            isMaker: true,
            dlcId: 'dlc-1',
          ),
        ),
        isFalse,
      );
    });
  });

  group('isDlcNegotiationComplete', () {
    test('true when funding txid is present', () {
      expect(
        isDlcNegotiationComplete(
          _order(status: 'filled', fundingTxid: 'abc', dlcStatus: 'signed'),
        ),
        isTrue,
      );
    });

    test('true after signing while funding broadcast is pending', () {
      expect(
        isDlcNegotiationComplete(
          _order(status: 'filled', dlcStatus: 'signed', dlcId: 'dlc-1'),
        ),
        isTrue,
      );
    });

    test('true when funding broadcast succeeded', () {
      expect(
        isDlcNegotiationComplete(
          _order(
            status: 'filled',
            dlcStatus: 'funding_broadcasted',
            dlcId: 'dlc-1',
          ),
        ),
        isTrue,
      );
    });
  });

  group('needsDlcNegotiation', () {
    test('true for pending accept, false after signed', () {
      expect(needsDlcNegotiation(_order(pendingMatchAccept: true)), isTrue);
      expect(
        needsDlcNegotiation(
          _order(status: 'filled', dlcStatus: 'signed', dlcId: 'dlc-1'),
        ),
        isFalse,
      );
    });
  });

  group('isCoordinatorOrderNotFound', () {
    test('true for HTTP 404 order not found', () {
      expect(
        isCoordinatorOrderNotFound(
          Exception('HTTP 404: not_found: Order not found'),
        ),
        isTrue,
      );
    });

    test('false for instrument not found', () {
      expect(
        isCoordinatorOrderNotFound(
          Exception('HTTP 404: Instrument not found'),
        ),
        isFalse,
      );
    });

    test('false for unrelated errors', () {
      expect(isCoordinatorOrderNotFound(Exception('HTTP 500: server error')), isFalse);
    });
  });

  group('isCoordinatorDlcNotFound', () {
    test('true for HTTP 404 DLC not found', () {
      expect(
        isCoordinatorDlcNotFound(Exception('HTTP 404: not_found: DLC not found')),
        isTrue,
      );
    });

    test('false for order not found', () {
      expect(
        isCoordinatorDlcNotFound(Exception('HTTP 404: Order not found')),
        isFalse,
      );
    });
  });

  group('isCoordinatorResourceNotFound', () {
    test('true for order or DLC 404', () {
      expect(
        isCoordinatorResourceNotFound(
          Exception('HTTP 404: not_found: DLC not found'),
        ),
        isTrue,
      );
      expect(
        isCoordinatorResourceNotFound(
          Exception('HTTP 404: not_found: Order not found'),
        ),
        isTrue,
      );
    });
  });

  group('isAcceptSigningNoLongerRequired', () {
    test('true for filled state conflict on accept-context', () {
      expect(
        isAcceptSigningNoLongerRequired(
          Exception(
            'HTTP 400: state_conflict: Order is not awaiting accept signing: filled',
          ),
        ),
        isTrue,
      );
    });

    test('false for unrelated validation errors', () {
      expect(
        isAcceptSigningNoLongerRequired(
          Exception('HTTP 400: validation_failed'),
        ),
        isFalse,
      );
    });
  });

  group('isBenignDlcNegotiationMessage', () {
    test('includes transient and accept state conflict', () {
      expect(
        isBenignDlcNegotiationMessage('No route to host'),
        isTrue,
      );
      expect(
        isBenignDlcNegotiationMessage(
          'state_conflict: Order is not awaiting accept signing: filled',
        ),
        isTrue,
      );
    });
  });

  group('isTransientDlcCoordinatorMessage', () {
    test('true for connection errors', () {
      expect(
        isTransientDlcCoordinatorMessage(
          'The connection errored: No route to host',
        ),
        isTrue,
      );
    });

    test('false for validation failures', () {
      expect(
        isTransientDlcCoordinatorMessage('HTTP 400: validation_failed'),
        isFalse,
      );
    });
  });

  group('isNegotiationAbandonedForOrderNotFound', () {
    test('true only for order_not_found status', () {
      expect(
        isNegotiationAbandonedForOrderNotFound(dlcNegotiationOrderNotFoundStatus),
        isTrue,
      );
      expect(isNegotiationAbandonedForOrderNotFound('accept_pending'), isFalse);
    });
  });
}
