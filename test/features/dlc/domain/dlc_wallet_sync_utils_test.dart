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

    test('suppresses benign partial UTXO rejection noise', () {
      expect(
        formatDlcWalletSyncInfoMessage(
          DlcWalletSyncResult.fromJson({
            'warning': '1 submitted UTXO(s) were rejected',
            'utxo_sync_error': '1 submitted UTXO(s) were rejected',
            'rejected_utxos': [
              {'txid': 'abc', 'vout': 0},
            ],
          }),
        ),
        isNull,
      );
    });

    test('still shows cancelled orders when benign warnings are present', () {
      final message = formatDlcWalletSyncInfoMessage(
        DlcWalletSyncResult.fromJson({
          'warning': '1 submitted UTXO(s) were rejected',
          'rejected_utxos': [
            {'txid': 'abc', 'vout': 0},
          ],
          'cancelled_orders': [
            {
              'order_id': 'order-1',
              'cancellation_reason': 'wallet_sync_missing_order_utxo',
            },
          ],
        }),
      );

      expect(message, contains('cancelled 1 open order'));
      expect(message, isNot(contains('submitted UTXO')));
      expect(message, isNot(contains('could not be synced')));
    });

    test('shows non-benign coordinator warnings', () {
      final message = formatDlcWalletSyncInfoMessage(
        DlcWalletSyncResult.fromJson({
          'warning':
              'ElectrumX sync degraded; balances were refreshed from tracked UTXOs only.',
        }),
      );

      expect(message, contains('ElectrumX sync degraded'));
    });
  });

  group('isBenignUtxoSyncUserMessage', () {
    test('recognizes submitted UTXO rejection copy', () {
      expect(
        isBenignUtxoSyncUserMessage('1 submitted UTXO(s) were rejected'),
        isTrue,
      );
    });
  });
}
