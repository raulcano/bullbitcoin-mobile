import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_wallet_sync_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatDlcWalletSyncInfoMessage', () {
    test('describes coordinator-cancelled open orders', () {
      final message = formatDlcWalletSyncInfoMessage(
        DlcWalletSyncResult.fromJson({
          'cancelled_orders': [
            {
              'order_id': 'order-1',
              'cancellation_reason': 'wallet_sync_spent_order_utxo',
            },
          ],
        }),
      );

      expect(message, contains('cancelled 1 open order'));
      expect(message, contains('funding UTXOs are no longer available'));
    });

    test('returns null when sync has nothing to report', () {
      expect(
        formatDlcWalletSyncInfoMessage(DlcWalletSyncResult.fromJson(const {})),
        isNull,
      );
    });
  });
}
