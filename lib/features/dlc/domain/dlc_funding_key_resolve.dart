import 'dart:typed_data';

import 'package:bip32_keys/bip32_keys.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/digests/ripemd160.dart';

/// Wallet UTXO metadata for finding funding-input signing keys in an isolate.
class DlcWalletUtxoHint {
  final String txId;
  final int vout;
  final List<int> scriptPubkey;
  final String address;
  final int addressKeyChain;

  const DlcWalletUtxoHint({
    required this.txId,
    required this.vout,
    required this.scriptPubkey,
    required this.address,
    required this.addressKeyChain,
  });

  Map<String, dynamic> toJson() => {
    'tx_id': txId,
    'vout': vout,
    'script_pubkey': scriptPubkey,
    'address': address,
    'address_key_chain': addressKeyChain,
  };

  factory DlcWalletUtxoHint.fromJson(Map<String, dynamic> json) {
    return DlcWalletUtxoHint(
      txId: json['tx_id'] as String,
      vout: json['vout'] as int,
      scriptPubkey: (json['script_pubkey'] as List<dynamic>).cast<int>(),
      address: json['address'] as String,
      addressKeyChain: json['address_key_chain'] as int,
    );
  }
}

/// Resolves one BIP32 key per coordinator funding input (offer inputs for maker sign).
List<({Uint8List privateKey, Uint8List publicKey})> resolveFundingInputSigningMaterials({
  required Uint8List seedBytes,
  required String walletDerivationPath,
  required String scriptTypeName,
  required List<DlcWalletUtxoHint> utxoHints,
  required List<String> fundingInputSighashesHex,
  required List<String> fundingInputAddresses,
  required List<String> fundingInputOutpoints,
}) {
  if (fundingInputSighashesHex.isEmpty) return const [];

  final root = Bip32Keys.fromSeed(seedBytes);
  final cache = <String, Bip32Keys>{};
  final addressToKey = <String, Bip32Keys>{};

  final neededOutpoints = fundingInputOutpoints
      .map((o) => o.trim().toLowerCase())
      .where((o) => o.isNotEmpty)
      .toSet();
  final neededAddresses = fundingInputAddresses
      .map((a) => a.trim())
      .where((a) => a.isNotEmpty)
      .toSet();

  for (final utxo in utxoHints) {
    final outpoint = '${utxo.txId.toLowerCase()}:${utxo.vout}';
    if (!neededOutpoints.contains(outpoint) &&
        !neededAddresses.contains(utxo.address)) {
      continue;
    }
    final key = _findKeyForUtxoHint(
      root: root,
      walletDerivationPath: walletDerivationPath,
      utxo: utxo,
      scriptTypeName: scriptTypeName,
      cache: cache,
    );
    if (key != null && utxo.address.isNotEmpty) {
      addressToKey[utxo.address] = key;
    }
  }

  final materials = <({Uint8List privateKey, Uint8List publicKey})>[];
  for (var i = 0; i < fundingInputSighashesHex.length; i++) {
    Bip32Keys? inputKey;
    if (i < fundingInputAddresses.length) {
      final address = fundingInputAddresses[i].trim();
      if (address.isNotEmpty) {
        inputKey = addressToKey[address];
        inputKey ??= _findKeyForAddressScan(
          root: root,
          walletDerivationPath: walletDerivationPath,
          address: address,
          utxoHints: utxoHints,
          scriptTypeName: scriptTypeName,
          cache: cache,
        );
      }
    }
    if (inputKey == null && i < fundingInputOutpoints.length) {
      final outpoint = fundingInputOutpoints[i].trim();
      if (outpoint.isNotEmpty) {
        inputKey = _findKeyForOutpointHint(
          root: root,
          walletDerivationPath: walletDerivationPath,
          outpoint: outpoint,
          utxoHints: utxoHints,
          scriptTypeName: scriptTypeName,
          cache: cache,
        );
      }
    }
    if (inputKey?.private == null) {
      throw ArgumentError(
        'No private key for DLC funding input ${i + 1} of '
        '${fundingInputSighashesHex.length}',
      );
    }
    materials.add(
      (
        privateKey: Uint8List.fromList(inputKey!.private!),
        publicKey: Uint8List.fromList(inputKey.public),
      ),
    );
  }
  return materials;
}

Bip32Keys? _findKeyForOutpointHint({
  required Bip32Keys root,
  required String walletDerivationPath,
  required String outpoint,
  required List<DlcWalletUtxoHint> utxoHints,
  required String scriptTypeName,
  required Map<String, Bip32Keys> cache,
}) {
  final parts = outpoint.split(':');
  if (parts.length != 2) return null;
  final txid = parts[0].toLowerCase();
  final vout = int.tryParse(parts[1]);
  if (vout == null) return null;

  for (final utxo in utxoHints) {
    if (utxo.txId.toLowerCase() != txid || utxo.vout != vout) continue;
    return _findKeyForUtxoHint(
      root: root,
      walletDerivationPath: walletDerivationPath,
      utxo: utxo,
      scriptTypeName: scriptTypeName,
      cache: cache,
    );
  }
  return null;
}

Bip32Keys? _findKeyForAddressScan({
  required Bip32Keys root,
  required String walletDerivationPath,
  required String address,
  required List<DlcWalletUtxoHint> utxoHints,
  required String scriptTypeName,
  required Map<String, Bip32Keys> cache,
}) {
  for (final chain in [0, 1]) {
    for (var index = 0; index < 1000; index++) {
      final path = '$walletDerivationPath/$chain/$index';
      final key = cache.putIfAbsent(path, () => root.derivePath(path));
      final script = _scriptPubkeyForKey(scriptTypeName, key);
      for (final utxo in utxoHints) {
        if (utxo.address == address &&
            _bytesEqual(script, utxo.scriptPubkey)) {
          return key;
        }
      }
    }
  }
  return null;
}

Bip32Keys? _findKeyForUtxoHint({
  required Bip32Keys root,
  required String walletDerivationPath,
  required DlcWalletUtxoHint utxo,
  required String scriptTypeName,
  required Map<String, Bip32Keys> cache,
}) {
  final chain = utxo.addressKeyChain == 1 ? 1 : 0;
  for (var index = 0; index < 1000; index++) {
    final path = '$walletDerivationPath/$chain/$index';
    final key = cache.putIfAbsent(path, () => root.derivePath(path));
    if (_bytesEqual(_scriptPubkeyForKey(scriptTypeName, key), utxo.scriptPubkey)) {
      return key;
    }
  }
  return null;
}

Uint8List _scriptPubkeyForKey(String scriptTypeName, Bip32Keys key) {
  final pubkeyHash = _hash160(key.public);
  switch (scriptTypeName) {
    case 'bip84':
      return Uint8List.fromList([0x00, 0x14, ...pubkeyHash]);
    case 'bip49':
      final redeemScript = [0x00, 0x14, ...pubkeyHash];
      final scriptHash = _hash160(redeemScript);
      return Uint8List.fromList([0xa9, 0x14, ...scriptHash, 0x87]);
    case 'bip44':
    default:
      return Uint8List.fromList([
        0x76,
        0xa9,
        0x14,
        ...pubkeyHash,
        0x88,
        0xac,
      ]);
  }
}

Uint8List _hash160(List<int> bytes) {
  final sha = crypto.sha256.convert(bytes).bytes;
  return RIPEMD160Digest().process(Uint8List.fromList(sha));
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
