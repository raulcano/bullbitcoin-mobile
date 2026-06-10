import 'dart:convert';
import 'dart:math';

import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/storage/data/datasources/key_value_storage/key_value_storage_datasource.dart';
import 'package:convert/convert.dart';

/// Persists idempotency keys for coordinator create/accept/sign calls so timeouts
/// can be retried with the same key without duplicating trades.
class DlcIdempotencyStorage {
  static const _mainnetKey = 'dlc_idempotency_keys_mainnet';
  static const _testnetKey = 'dlc_idempotency_keys_testnet';

  final KeyValueStorageDatasource<String> _secureStorage;

  DlcIdempotencyStorage({
    required KeyValueStorageDatasource<String> secureStorage,
  }) : _secureStorage = secureStorage;

  String _storageKey(Environment environment) =>
      environment.isTestnet ? _testnetKey : _mainnetKey;

  Future<void> clear(Environment environment) async {
    await _secureStorage.saveValue(key: _storageKey(environment), value: '');
  }

  Future<String> getOrCreateCreateDraftKey({
    required Environment environment,
    required String draftFingerprint,
  }) async {
    final store = await _load(environment);
    store.createByDraft.putIfAbsent(draftFingerprint, () => _newKey());
    await _save(environment, store);
    return store.createByDraft[draftFingerprint]!;
  }

  Future<void> clearCreateDraftKey({
    required Environment environment,
    required String draftFingerprint,
  }) async {
    final store = await _load(environment);
    store.createByDraft.remove(draftFingerprint);
    await _save(environment, store);
  }

  Future<String> getOrCreateAcceptKey({
    required Environment environment,
    required String orderId,
  }) async {
    return getOrCreateAcceptKeyForFingerprint(
      environment: environment,
      orderId: orderId,
      contextFingerprint: '',
    );
  }

  Future<String> getOrCreateAcceptKeyForFingerprint({
    required Environment environment,
    required String orderId,
    required String contextFingerprint,
  }) async {
    final store = await _load(environment);
    final key = _acceptStorageKey(orderId, contextFingerprint);
    store.acceptByOrder.putIfAbsent(key, () => _newKey('accept'));
    await _save(environment, store);
    return store.acceptByOrder[key]!;
  }

  Future<void> rotateAcceptKey({
    required Environment environment,
    required String orderId,
    String contextFingerprint = '',
  }) async {
    final store = await _load(environment);
    final key = _acceptStorageKey(orderId, contextFingerprint);
    store.acceptByOrder[key] = _newKey('accept');
    await _save(environment, store);
  }

  Future<void> clearAcceptKey({
    required Environment environment,
    required String orderId,
    String contextFingerprint = '',
  }) async {
    final store = await _load(environment);
    store.acceptByOrder.remove(_acceptStorageKey(orderId, contextFingerprint));
    await _save(environment, store);
  }

  Future<String> getOrCreateSignKey({
    required Environment environment,
    required String dlcId,
  }) async {
    return getOrCreateSignKeyForFingerprint(
      environment: environment,
      dlcId: dlcId,
      contextFingerprint: '',
    );
  }

  Future<String> getOrCreateSignKeyForFingerprint({
    required Environment environment,
    required String dlcId,
    required String contextFingerprint,
  }) async {
    final store = await _load(environment);
    final key = _signStorageKey(dlcId, contextFingerprint);
    store.signByDlc.putIfAbsent(key, () => _newKey('sign'));
    await _save(environment, store);
    return store.signByDlc[key]!;
  }

  Future<void> rotateSignKey({
    required Environment environment,
    required String dlcId,
    String contextFingerprint = '',
  }) async {
    final store = await _load(environment);
    final key = _signStorageKey(dlcId, contextFingerprint);
    store.signByDlc[key] = _newKey('sign');
    await _save(environment, store);
  }

  Future<void> clearSignKey({
    required Environment environment,
    required String dlcId,
    String contextFingerprint = '',
  }) async {
    final store = await _load(environment);
    store.signByDlc.remove(_signStorageKey(dlcId, contextFingerprint));
    await _save(environment, store);
  }

  Future<void> clearAllKeysForOrder({
    required Environment environment,
    required String orderId,
  }) async {
    final store = await _load(environment);
    store.acceptByOrder.removeWhere(
      (key, _) => key == orderId || key.startsWith('$orderId:'),
    );
    await _save(environment, store);
  }

  Future<void> clearAllKeysForDlc({
    required Environment environment,
    required String dlcId,
  }) async {
    final store = await _load(environment);
    store.signByDlc.removeWhere(
      (key, _) => key == dlcId || key.startsWith('$dlcId:'),
    );
    await _save(environment, store);
  }

  String _acceptStorageKey(String orderId, String contextFingerprint) {
    final fp = contextFingerprint.trim();
    return fp.isEmpty ? orderId : '$orderId:$fp';
  }

  String _signStorageKey(String dlcId, String contextFingerprint) {
    final fp = contextFingerprint.trim();
    return fp.isEmpty ? dlcId : '$dlcId:$fp';
  }

  String _newKey([String prefix = '']) {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final token = hex.encode(bytes);
    return prefix.isEmpty ? token : '$prefix-$token';
  }

  Future<_IdempotencyPayload> _load(Environment environment) async {
    final raw = await _secureStorage.getValue(_storageKey(environment));
    if (raw == null || raw.isEmpty) return _IdempotencyPayload.empty();
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return _IdempotencyPayload.fromJson(map);
    } catch (_) {
      return _IdempotencyPayload.empty();
    }
  }

  Future<void> _save(Environment environment, _IdempotencyPayload store) async {
    await _secureStorage.saveValue(
      key: _storageKey(environment),
      value: jsonEncode(store.toJson()),
    );
  }
}

class _IdempotencyPayload {
  final Map<String, String> createByDraft;
  final Map<String, String> acceptByOrder;
  final Map<String, String> signByDlc;

  _IdempotencyPayload({
    required this.createByDraft,
    required this.acceptByOrder,
    required this.signByDlc,
  });

  factory _IdempotencyPayload.empty() =>
      _IdempotencyPayload(createByDraft: {}, acceptByOrder: {}, signByDlc: {});

  factory _IdempotencyPayload.fromJson(Map<String, dynamic> json) {
    Map<String, String> readMap(String key) {
      final raw = json[key];
      if (raw is! Map) return {};
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }

    return _IdempotencyPayload(
      createByDraft: readMap('createByDraft'),
      acceptByOrder: readMap('acceptByOrder'),
      signByDlc: readMap('signByDlc'),
    );
  }

  Map<String, dynamic> toJson() => {
    'createByDraft': createByDraft,
    'acceptByOrder': acceptByOrder,
    'signByDlc': signByDlc,
  };
}
