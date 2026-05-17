import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';

/// Coordinator noise when one or more UTXO proofs fail but trading can continue.
bool isBenignUtxoSyncUserMessage(String message) {
  final lower = message.toLowerCase();
  if (lower.contains('submitted utxo') && lower.contains('reject')) {
    return true;
  }
  if (lower.contains('could not be synced') && lower.contains('skip')) {
    return true;
  }
  return false;
}

bool _isBenignPartialUtxoSyncOnly(DlcWalletSyncResult sync) {
  if (sync.hasCancelledOrders) return false;

  final textMessages = <String?>[
    sync.warning?.trim(),
    sync.utxoSyncError?.trim(),
  ].whereType<String>().where((part) => part.isNotEmpty).toList(growable: false);

  if (textMessages.isNotEmpty &&
      !textMessages.every(isBenignUtxoSyncUserMessage)) {
    return false;
  }

  return textMessages.isNotEmpty || sync.rejectedUtxos.isNotEmpty;
}

List<String> _uniqueNonEmpty(Iterable<String?> values) {
  final seen = <String>{};
  final unique = <String>[];
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty || !seen.add(trimmed)) continue;
    unique.add(trimmed);
  }
  return unique;
}

/// User-facing summary after [DlcWalletSyncResult] (e.g. open orders cancelled by sync).
///
/// Routine partial UTXO rejections are suppressed; cancelled orders and hard sync
/// problems are still surfaced.
String? formatDlcWalletSyncInfoMessage(DlcWalletSyncResult? sync) {
  if (sync == null) return null;
  final parts = <String>[];

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

  for (final message in _uniqueNonEmpty([sync.warning, sync.utxoSyncError])) {
    if (!isBenignUtxoSyncUserMessage(message)) {
      parts.add(message);
    }
  }

  final rejected = sync.rejectedUtxos.length;
  if (rejected > 0 &&
      !sync.hasCancelledOrders &&
      !_isBenignPartialUtxoSyncOnly(sync)) {
    parts.add(
      '$rejected UTXO${rejected == 1 ? '' : 's'} could not be synced and were skipped.',
    );
  }

  if (parts.isEmpty) return null;
  return parts.join(' ');
}
