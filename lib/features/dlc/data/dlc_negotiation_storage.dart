import 'dart:convert';

import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/storage/data/datasources/key_value_storage/key_value_storage_datasource.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_negotiation_utils.dart';

/// Local negotiation metadata keyed by wallet + order (funding pubkey, fingerprints).
class DlcNegotiationStorage {
  static const _mainnetKey = 'dlc_negotiation_state_mainnet';
  static const _testnetKey = 'dlc_negotiation_state_testnet';

  final KeyValueStorageDatasource<String> _secureStorage;

  DlcNegotiationStorage({
    required KeyValueStorageDatasource<String> secureStorage,
  }) : _secureStorage = secureStorage;

  String _storageKey(Environment environment) =>
      environment.isTestnet ? _testnetKey : _mainnetKey;

  Future<void> clear(Environment environment) async {
    await _secureStorage.saveValue(key: _storageKey(environment), value: '');
  }

  Future<Map<String, dynamic>?> getOrderState({
    required Environment environment,
    required String walletOriginId,
    required String orderId,
  }) async {
    final store = await _load(environment);
    final wallet = store[walletOriginId];
    if (wallet is! Map) return null;
    final order = wallet[orderId];
    if (order is! Map) return null;
    return Map<String, dynamic>.from(order);
  }

  Future<bool> isOrderAbandonedNotFound({
    required Environment environment,
    required String walletOriginId,
    required String orderId,
  }) async {
    final state = await getOrderState(
      environment: environment,
      walletOriginId: walletOriginId,
      orderId: orderId,
    );
    return isNegotiationAbandonedForOrderNotFound(
      state?['negotiation_status'] as String?,
    );
  }

  Future<void> markOrderNotFoundOnCoordinator({
    required Environment environment,
    required String walletOriginId,
    required String orderId,
  }) async {
    await upsertOrderState(
      environment: environment,
      walletOriginId: walletOriginId,
      orderId: orderId,
      values: {
        'negotiation_status': dlcNegotiationOrderNotFoundStatus,
        'abandoned_at': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  Future<void> removeOrderState({
    required Environment environment,
    required String walletOriginId,
    required String orderId,
  }) async {
    final store = await _load(environment);
    final wallet = store[walletOriginId];
    if (wallet is! Map) return;
    final updated = Map<String, dynamic>.from(wallet);
    updated.remove(orderId);
    if (updated.isEmpty) {
      store.remove(walletOriginId);
    } else {
      store[walletOriginId] = updated;
    }
    await _save(environment, store);
  }

  Future<void> upsertOrderState({
    required Environment environment,
    required String walletOriginId,
    required String orderId,
    required Map<String, dynamic> values,
  }) async {
    final store = await _load(environment);
    final wallet =
        Map<String, dynamic>.from(store[walletOriginId] as Map? ?? {});
    final existing = Map<String, dynamic>.from(
      wallet[orderId] as Map? ?? {},
    );
    wallet[orderId] = {...existing, ...values, 'order_id': orderId};
    store[walletOriginId] = wallet;
    await _save(environment, store);
  }

  Future<Map<String, dynamic>> _load(Environment environment) async {
    final raw = await _secureStorage.getValue(_storageKey(environment));
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return {};
  }

  Future<void> _save(
    Environment environment,
    Map<String, dynamic> store,
  ) async {
    await _secureStorage.saveValue(
      key: _storageKey(environment),
      value: jsonEncode(store),
    );
  }
}
