import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_explorer_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:flutter_test/flutter_test.dart';

DlcOrderSummary _order({String? dlcId, String? matchedDlcId}) {
  return DlcOrderSummary(
    orderId: 'order-1',
    dlcId: dlcId,
    status: 'filled',
    pendingMatchAccept: false,
    matchedOrderId: null,
    matchedDlcId: matchedDlcId,
    isMaker: true,
    matchRole: 'maker',
    signRequired: null,
    dlcStatus: 'signed',
    settlementType: null,
    confirmationStatus: null,
    instrumentId: null,
    side: 'sell',
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
  group('dlcExplorerDlcIdForOrder', () {
    test('prefers order dlcId', () {
      expect(
        dlcExplorerDlcIdForOrder(
          _order(dlcId: 'dlc-primary', matchedDlcId: 'dlc-other'),
        ),
        'dlc-primary',
      );
    });

    test('falls back to matchedDlcId', () {
      expect(
        dlcExplorerDlcIdForOrder(_order(matchedDlcId: 'dlc-matched')),
        'dlc-matched',
      );
    });

    test('returns null when no dlc id is available', () {
      expect(dlcExplorerDlcIdForOrder(_order()), isNull);
    });
  });

  group('dlcExplorerDashboardPostUrl', () {
    test('uses configured explorer URL with trailing slash', () {
      ApiServiceConstants.dlcExplorerBaseUrl = 'http://backend.coldpay.de:8300';
      expect(
        dlcExplorerDashboardPostUrl(Environment.mainnet),
        'http://backend.coldpay.de:8300/',
      );
    });

    test('selects testnet URL when environment is testnet', () {
      ApiServiceConstants.dlcExplorerTestBaseUrl =
          'http://backend.coldpay.de:3001';
      expect(
        dlcExplorerDashboardPostUrl(Environment.testnet),
        'http://backend.coldpay.de:3001/',
      );
    });
  });

  group('dlcExplorerFormUrlEncodedBody', () {
    test('encodes wallet_token and dlc_id without putting token in URL', () {
      const token = 'wallet-token/with+special&chars=';
      const dlcId = 'dlc-42';

      final body = dlcExplorerFormUrlEncodedBody(
        walletToken: token,
        dlcId: dlcId,
      );

      expect(body, contains('wallet_token='));
      expect(body, contains('dlc_id=dlc-42'));
      expect(body, isNot(contains('?')));
      expect(Uri.decodeComponent(body.split('&').first.split('=').last), token);
    });
  });

  group('dlcExplorerAutoSubmitHtml', () {
    test('builds auto-submit POST form without pre-encoding field values', () {
      const token = 'prt_abc&def+ghi"quote';

      final page = dlcExplorerAutoSubmitHtml(
        dashboardUrl: 'http://backend.coldpay.de:8300/',
        walletToken: token,
        dlcId: 'dlc-99',
      );

      expect(page, contains('method="post"'));
      expect(page, contains('action="http://backend.coldpay.de:8300/"'));
      expect(page, contains('name="wallet_token"'));
      expect(page, contains('name="dlc_id"'));
      expect(page, contains('value="dlc-99"'));
      expect(page, contains('.submit();'));
      expect(page, isNot(contains('%26')));
      expect(page, isNot(contains('wallet_token=prt')));
    });
  });
}
