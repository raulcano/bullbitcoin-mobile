import 'dart:convert';

import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/storage/data/datasources/key_value_storage/key_value_storage_datasource.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';

class DlcAuthStorage {
  static const _mainnetKey = 'dlc_wallet_auth_mainnet';
  static const _testnetKey = 'dlc_wallet_auth_testnet';

  final KeyValueStorageDatasource<String> _secureStorage;

  DlcAuthStorage({required KeyValueStorageDatasource<String> secureStorage})
    : _secureStorage = secureStorage;

  String _storageKey(Environment environment) =>
      environment.isTestnet ? _testnetKey : _mainnetKey;

  Future<void> store(Environment environment, DlcWalletAuth auth) async {
    final all = await getAll(environment);
    all.removeWhere((item) => item.walletOriginId == auth.walletOriginId);
    all.add(auth);
    await _saveAll(environment, all, activeWalletOriginId: auth.walletOriginId);
  }

  Future<DlcWalletAuth?> get(Environment environment) async {
    final decoded = await _decode(environment);
    if (decoded == null) return null;
    final all = decoded.entries;
    if (all.isEmpty) return null;
    final activeOriginId = decoded.activeWalletOriginId;
    if (activeOriginId != null) {
      final match = all.where((item) => item.walletOriginId == activeOriginId);
      if (match.isNotEmpty) return match.first;
    }
    return all.first;
  }

  Future<List<DlcWalletAuth>> getAll(Environment environment) async {
    final raw = await _secureStorage.getValue(_storageKey(environment));
    if (raw == null || raw.isEmpty) return [];
    final map = jsonDecode(raw) as Map<String, dynamic>;
    if (map['entries'] is List) {
      return (map['entries'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(_fromMap)
          .toList(growable: false);
    }
    // Backward compatibility with old single-entry payload.
    if (map.containsKey('walletId') && map.containsKey('walletToken')) {
      return [_fromMap(map)];
    }
    return [];
  }

  Future<void> setActiveWalletOriginId(
    Environment environment,
    String walletOriginId,
  ) async {
    final all = await getAll(environment);
    if (!all.any((item) => item.walletOriginId == walletOriginId)) return;
    await _saveAll(environment, all, activeWalletOriginId: walletOriginId);
  }

  Future<void> removeByWalletOriginId(
    Environment environment,
    String walletOriginId,
  ) async {
    final decoded = await _decode(environment);
    if (decoded == null) return;
    final next = decoded.entries
        .where((item) => item.walletOriginId != walletOriginId)
        .toList();
    final nextActive = decoded.activeWalletOriginId == walletOriginId
        ? (next.isEmpty ? null : next.first.walletOriginId)
        : decoded.activeWalletOriginId;
    await _saveAll(environment, next, activeWalletOriginId: nextActive);
  }

  Future<void> clear(Environment environment) async {
    await _secureStorage.deleteValue(_storageKey(environment));
  }

  Future<void> _saveAll(
    Environment environment,
    List<DlcWalletAuth> entries, {
    String? activeWalletOriginId,
  }) async {
    final payload = jsonEncode({
      'activeWalletOriginId': activeWalletOriginId,
      'entries': entries.map(_toMap).toList(growable: false),
    });
    await _secureStorage.saveValue(
      key: _storageKey(environment),
      value: payload,
    );
  }

  Future<_DecodedAuthStorage?> _decode(Environment environment) async {
    final all = await getAll(environment);
    if (all.isEmpty) return null;
    final raw = await _secureStorage.getValue(_storageKey(environment));
    String? active;
    if (raw != null && raw.isNotEmpty) {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      active = map['activeWalletOriginId'] as String?;
    }
    return _DecodedAuthStorage(entries: all, activeWalletOriginId: active);
  }

  DlcWalletAuth _fromMap(Map<String, dynamic> map) {
    return DlcWalletAuth(
      walletOriginId: map['walletOriginId'] as String? ?? '',
      walletLabel: map['walletLabel'] as String? ?? 'Bitcoin wallet',
      walletXpub: map['walletXpub'] as String? ?? '',
      walletId: map['walletId'] as String,
      walletToken: map['walletToken'] as String,
      expiresAt: map['expiresAt'] == null
          ? null
          : DateTime.tryParse(map['expiresAt'] as String),
    );
  }

  Map<String, dynamic> _toMap(DlcWalletAuth auth) {
    return {
      'walletOriginId': auth.walletOriginId,
      'walletLabel': auth.walletLabel,
      'walletXpub': auth.walletXpub,
      'walletId': auth.walletId,
      'walletToken': auth.walletToken,
      'expiresAt': auth.expiresAt?.toIso8601String(),
    };
  }
}

class _DecodedAuthStorage {
  final List<DlcWalletAuth> entries;
  final String? activeWalletOriginId;

  const _DecodedAuthStorage({
    required this.entries,
    required this.activeWalletOriginId,
  });
}
