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
    matchedOrderId: null,
    matchedDlcId: null,
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
