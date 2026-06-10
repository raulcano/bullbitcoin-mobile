import 'dart:convert';

import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/storage/data/datasources/key_value_storage/key_value_storage_datasource.dart';

class DlcOrderStorage {
  static const _mainnetKey = 'dlc_order_snapshots_mainnet';
  static const _testnetKey = 'dlc_order_snapshots_testnet';

  final KeyValueStorageDatasource<String> _secureStorage;

  DlcOrderStorage({required KeyValueStorageDatasource<String> secureStorage})
    : _secureStorage = secureStorage;

  String _storageKey(Environment environment) =>
      environment.isTestnet ? _testnetKey : _mainnetKey;

  Future<void> clear(Environment environment) async {
    await _secureStorage.saveValue(key: _storageKey(environment), value: '');
  }

  Future<void> upsertOrder({
    required Environment environment,
    required String walletOriginId,
    required Map<String, dynamic> values,
  }) async {
    final orderId = values['order_id']?.toString();
    if (orderId == null || orderId.isEmpty) return;
    final store = await _load(environment);
    final key = _key(walletOriginId, orderId);
    store[key] = {
      ...?store[key],
      ...values,
      'wallet_origin_id': walletOriginId,
      'last_coordinator_sync_at': DateTime.now().toUtc().toIso8601String(),
    };
    await _save(environment, store);
  }

  Future<void> upsertDlc({
    required Environment environment,
    required String walletOriginId,
    required String dlcId,
    required Map<String, dynamic> values,
  }) async {
    final store = await _load(environment);
    final match = store.entries.where(
      (entry) =>
          entry.value['wallet_origin_id'] == walletOriginId &&
          entry.value['dlc_id'] == dlcId,
    );
    final key = match.isEmpty
        ? _key(walletOriginId, 'dlc:$dlcId')
        : match.first.key;
    store[key] = {
      ...?store[key],
      ...values,
      'wallet_origin_id': walletOriginId,
      'dlc_id': dlcId,
      'last_coordinator_sync_at': DateTime.now().toUtc().toIso8601String(),
    };
    await _save(environment, store);
  }

  Future<Map<String, dynamic>?> getByOrderId({
    required Environment environment,
    required String walletOriginId,
    required String orderId,
  }) async {
    final store = await _load(environment);
    return store[_key(walletOriginId, orderId)];
  }

  Future<void> removeOrder({
    required Environment environment,
    required String walletOriginId,
    required String orderId,
  }) async {
    final store = await _load(environment);
    final keysToRemove = store.entries
        .where(
          (entry) =>
              entry.value['wallet_origin_id'] == walletOriginId &&
              (entry.key == _key(walletOriginId, orderId) ||
                  entry.value['order_id']?.toString() == orderId),
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final key in keysToRemove) {
      store.remove(key);
    }
    await _save(environment, store);
  }

  Future<String?> orderIdForDlcId({
    required Environment environment,
    required String walletOriginId,
    required String dlcId,
  }) async {
    final store = await _load(environment);
    for (final entry in store.entries) {
      if (entry.value['wallet_origin_id'] != walletOriginId) continue;
      if (entry.value['dlc_id']?.toString() == dlcId) {
        final orderId = entry.value['order_id']?.toString();
        if (orderId != null && orderId.isNotEmpty) return orderId;
      }
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> listForWallet({
    required Environment environment,
    required String walletOriginId,
  }) async {
    final store = await _load(environment);
    return store.values
        .where((item) => item['wallet_origin_id'] == walletOriginId)
        .map(Map<String, dynamic>.from)
        .toList(growable: false);
  }

  String _key(String walletOriginId, String orderId) =>
      '$walletOriginId::$orderId';

  Future<Map<String, Map<String, dynamic>>> _load(
    Environment environment,
  ) async {
    final raw = await _secureStorage.getValue(_storageKey(environment));
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (key, value) => MapEntry(
          key,
          value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{},
        ),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(
    Environment environment,
    Map<String, Map<String, dynamic>> store,
  ) async {
    await _secureStorage.saveValue(
      key: _storageKey(environment),
      value: jsonEncode(store),
    );
  }
}
