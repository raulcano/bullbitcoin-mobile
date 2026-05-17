import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';

/// User-facing summary after [DlcWalletSyncResult] (e.g. open orders cancelled by sync).
String? formatDlcWalletSyncInfoMessage(DlcWalletSyncResult? sync) {
  if (sync == null) return null;
  final parts = <String>[];

  final warning = sync.warning?.trim();
  if (warning != null && warning.isNotEmpty) {
    parts.add(warning);
  }

  final syncError = sync.utxoSyncError?.trim();
  if (syncError != null && syncError.isNotEmpty) {
    parts.add(syncError);
  }

  if (sync.hasCancelledOrders) {
    final count = sync.cancelledOrders.length;
    final reasons = sync.cancelledOrders
        .map((order) => order['cancellation_reason']?.toString().trim())
        .whereType<String>()
        .where((reason) => reason.isNotEmpty)
        .toSet();
    final reasonHint = reasons.contains('wallet_sync_missing_order_utxo') ||
            reasons.contains('wallet_sync_spent_order_utxo')
        ? ' because their funding UTXOs are no longer available on the coordinator.'
        : '.';
    parts.add(
      'UTXO sync cancelled $count open order${count == 1 ? '' : 's'}$reasonHint',
    );
  }

  final rejected = sync.rejectedUtxos.length;
  if (rejected > 0) {
    parts.add(
      '$rejected UTXO${rejected == 1 ? '' : 's'} could not be synced and were skipped.',
    );
  }

  if (parts.isEmpty) return null;
  return parts.join(' ');
}
