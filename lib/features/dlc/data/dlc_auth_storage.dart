import 'dart:convert';

import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/storage/data/datasources/key_value_storage/key_value_storage_datasource.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';

class DlcAuthStorage {
  static const _mainnetKey = 'dlc_wallet_auth_mainnet';
  static const _testnetKey = 'dlc_wallet_auth_testnet';

  final KeyValueStorageDatasource<String> _secureStorage;

  DlcAuthStorage({
    required KeyValueStorageDatasource<String> secureStorage,
  }) : _secureStorage = secureStorage;

  String _storageKey(Environment environment) =>
      environment.isTestnet ? _testnetKey : _mainnetKey;

  Future<void> store(Environment environment, DlcWalletAuth auth) async {
    final payload = jsonEncode({
      'walletId': auth.walletId,
      'walletToken': auth.walletToken,
      'expiresAt': auth.expiresAt?.toIso8601String(),
    });
    await _secureStorage.saveValue(key: _storageKey(environment), value: payload);
  }

  Future<DlcWalletAuth?> get(Environment environment) async {
    final raw = await _secureStorage.getValue(_storageKey(environment));
    if (raw == null || raw.isEmpty) return null;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return DlcWalletAuth(
      walletId: map['walletId'] as String,
      walletToken: map['walletToken'] as String,
      expiresAt: map['expiresAt'] == null
          ? null
          : DateTime.tryParse(map['expiresAt'] as String),
    );
  }

  Future<void> clear(Environment environment) async {
    await _secureStorage.deleteValue(_storageKey(environment));
  }
}
