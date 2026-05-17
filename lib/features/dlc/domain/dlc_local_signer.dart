import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_mobile/core/seed/data/repository/seed_repository.dart';
import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/utils/address_script_conversions.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet_address.dart';
import 'package:bb_mobile/core/utils/uint_8_list_x.dart';
import 'package:bb_mobile/core/wallet/data/repositories/wallet_repository.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet_utxo.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_context_signing_isolate.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_ecdsa_der.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bip32_keys/bip32_keys.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/digests/ripemd160.dart';

/// Local signer for DLC coordinator accept/sign flows.
///
/// Heavy signing (CET adaptors, refund, funding witnesses) runs in a background
/// isolate via [runDlcContextSigningOffMainThread] so the UI thread stays responsive.
class DlcLocalSigner {
  final WalletRepository _walletRepository;
  final SeedRepository _seedRepository;

  DlcLocalSigner({
    required WalletRepository walletRepository,
    required SeedRepository seedRepository,
  }) : _walletRepository = walletRepository,
       _seedRepository = seedRepository;

  Future<Wallet> getDefaultBitcoinWallet(Environment environment) async {
    final wallets = await _walletRepository.getWallets(
      environment: environment,
      onlyDefaults: true,
      onlyBitcoin: true,
    );
    if (wallets.isEmpty) {
      throw Exception(
        'No default Bitcoin wallet found for ${environment.name}.',
      );
    }
    return wallets.first;
  }

  Future<List<Wallet>> getBitcoinWallets(Environment environment) async {
    final wallets = await _walletRepository.getWallets(
      environment: environment,
      onlyBitcoin: true,
    );
    return wallets
        .where((wallet) => wallet.isBitcoin && !wallet.isLiquid)
        .toList(growable: false);
  }

  Future<Wallet> getBitcoinWalletByOriginId({
    required Environment environment,
    required String walletOriginId,
  }) async {
    final wallets = await getBitcoinWallets(environment);
    final match = wallets.where((w) => w.id == walletOriginId);
    if (match.isEmpty) {
      throw Exception('Bitcoin wallet not found: $walletOriginId');
    }
    return match.first;
  }

  Future<String> deriveFundingPubkeyHex({required Wallet wallet}) async {
    final funding = await deriveFundingPubkey(wallet: wallet);
    return funding.pubkeyHex;
  }

  Future<DlcFundingPubkey> deriveFundingPubkey({required Wallet wallet}) async {
    final seed = await _seedRepository.get(wallet.masterFingerprint);
    final derivationPath = fundingDerivationPath(wallet);
    final key = _deriveDlcKey(
      seedBytes: seed.bytes,
      derivationPath: derivationPath,
    );
    return DlcFundingPubkey(
      pubkeyHex: key.public.toHexString(),
      derivationPath: derivationPath,
    );
  }

  Future<String> signNonceProof({
    required Wallet wallet,
    required String nonce,
  }) async {
    final seed = await _seedRepository.get(wallet.masterFingerprint);
    final key = _deriveWalletAccountKey(seedBytes: seed.bytes, wallet: wallet);
    final hash = sha256.convert(utf8.encode(nonce)).bytes;
    final signature = Uint8List.fromList(
      key.sign(Uint8List.fromList(hash)) as List<int>,
    );
    return compactSecp256k1SignatureToDerHex(signature, includeHashType: true);
  }

  Future<List<String>> signNonceProofCandidates({
    required Wallet wallet,
    required String nonce,
  }) async {
    final seed = await _seedRepository.get(wallet.masterFingerprint);
    final accountKey = _deriveWalletAccountKey(
      seedBytes: seed.bytes,
      wallet: wallet,
    );
    final interactionKey = _deriveDlcKey(
      seedBytes: seed.bytes,
      derivationPath: fundingDerivationPath(wallet),
    );
    final nonceHex = utf8.encode(nonce).toHexString();

    Uint8List signDigest(Bip32Keys key, List<int> digest) =>
        Uint8List.fromList(key.sign(Uint8List.fromList(digest)) as List<int>);

    final signatures = <String>[
      compactSecp256k1SignatureToDerHex(
        signDigest(accountKey, sha256.convert(utf8.encode(nonce)).bytes),
        includeHashType: true,
      ),
      compactSecp256k1SignatureToDerHex(
        signDigest(accountKey, sha256.convert(utf8.encode(nonceHex)).bytes),
        includeHashType: true,
      ),
      compactSecp256k1SignatureToDerHex(
        signDigest(
          accountKey,
          sha256.convert(sha256.convert(utf8.encode(nonce)).bytes).bytes,
        ),
        includeHashType: true,
      ),
      compactSecp256k1SignatureToDerHex(
        signDigest(interactionKey, sha256.convert(utf8.encode(nonce)).bytes),
        includeHashType: true,
      ),
      compactSecp256k1SignatureToDerHex(
        signDigest(interactionKey, sha256.convert(utf8.encode(nonceHex)).bytes),
        includeHashType: true,
      ),
    ];

    return signatures.toSet().toList(growable: false);
  }

  Future<String> signUtxoProof({
    required Wallet wallet,
    required String txid,
    required int vout,
  }) async {
    final seed = await _seedRepository.get(wallet.masterFingerprint);
    final key = _deriveDlcKey(
      seedBytes: seed.bytes,
      derivationPath: fundingDerivationPath(wallet),
    );
    final hash = sha256.convert(utf8.encode('$txid:$vout')).bytes;
    final signature = key.sign(Uint8List.fromList(hash));
    return Uint8List.fromList(signature).toHexString();
  }

  Future<List<Map<String, dynamic>>> buildUtxoProofs({
    required Wallet wallet,
    required List<WalletUtxo> utxos,
    required String nonce,
  }) async {
    final bitcoinUtxos = utxos
        .whereType<BitcoinWalletUtxo>()
        .where((utxo) => !utxo.isFrozen)
        .toList(growable: false);
    if (bitcoinUtxos.isEmpty) return const [];

    final seed = await _seedRepository.get(wallet.masterFingerprint);
    final root = Bip32Keys.fromSeed(seed.bytes);
    final proofs = <Map<String, dynamic>>[];
    final cache = <String, Bip32Keys>{};

    for (final utxo in bitcoinUtxos) {
      final key = _findKeyForUtxo(
        root: root,
        wallet: wallet,
        utxo: utxo,
        cache: cache,
      );
      if (key == null) continue;
      final messageBytes = utf8.encode('${utxo.txId}${utxo.vout}$nonce');
      final digest = sha256.convert(messageBytes).bytes;
      final signature = Uint8List.fromList(
        key.sign(Uint8List.fromList(digest)) as List<int>,
      );
      proofs.add({
        'txid': utxo.txId,
        'vout': utxo.vout,
        'signature': compactSecp256k1SignatureToDerHex(signature),
        'public_key': key.public.toHexString(),
      });
    }
    return proofs;
  }

  Future<DlcSigningResult> signDlcContext({
    required Wallet wallet,
    required String contextTag,
    required Map<String, dynamic> context,
    required String fundingPubkeyHex,
    required List<WalletUtxo> walletUtxos,
  }) async {
    final seed = await _seedRepository.get(wallet.masterFingerprint);
    final key = _deriveDlcKey(
      seedBytes: seed.bytes,
      derivationPath: fundingDerivationPath(wallet),
    );

    final jobs = context['cet_signing_jobs'] as List<dynamic>? ?? const [];
    final expectedJobCount = context['cet_signing_job_count'] as int?;
    if (expectedJobCount != null && expectedJobCount != jobs.length) {
      throw Exception(
        'Signing context job count mismatch: expected $expectedJobCount, got ${jobs.length}',
      );
    }
    final fundingPrivateKey = key.private;
    if (fundingPrivateKey == null || fundingPrivateKey.length != 32) {
      throw Exception('DLC funding key is missing or invalid.');
    }

    final fundingHashes =
        (context['funding_input_sighashes_hex'] as List<dynamic>? ?? const [])
            .cast<String>();
    final fundingInputKeys = await _resolveFundingInputSigningKeys(
      wallet: wallet,
      walletUtxos: walletUtxos,
      fundingInputSighashesHex: fundingHashes,
      fundingInputAddresses: (context['funding_input_addresses'] as List<dynamic>? ??
              const [])
          .map((item) => item.toString())
          .toList(growable: false),
      fundingInputOutpoints: (context['funding_input_outpoints'] as List<dynamic>? ??
              const [])
          .map((item) => item.toString())
          .toList(growable: false),
    );

    final signed = await runDlcContextSigningOffMainThread(
      DlcContextSigningIsolateInput(
        cetSigningJobs: jobs
            .map((job) => Map<String, dynamic>.from(job as Map))
            .toList(growable: false),
        fundingPrivateKey: fundingPrivateKey,
        contextTag: contextTag,
        refundSighashHex: context['refund_sighash_hex'] as String?,
        fundingInputSighashesHex: fundingHashes,
        fundingInputKeys: fundingInputKeys
            .map(
              (k) => DlcFundingInputSigningMaterial(
                privateKey: k.private!,
                publicKey: k.public,
              ),
            )
            .toList(growable: false),
      ),
    );

    return DlcSigningResult(
      fundingPubkeyHex: fundingPubkeyHex,
      cetAdaptorSignaturesHex: signed.cetAdaptorSignaturesHex,
      refundSignatureHex: signed.refundSignatureHex,
      fundingSignaturesHex: signed.fundingSignaturesHex,
    );
  }

  String fundingDerivationPath(Wallet wallet) => '${wallet.derivationPath}/0/0';

  Future<List<Bip32Keys>> _resolveFundingInputSigningKeys({
    required Wallet wallet,
    required List<WalletUtxo> walletUtxos,
    required List<String> fundingInputSighashesHex,
    required List<String> fundingInputAddresses,
    required List<String> fundingInputOutpoints,
  }) async {
    final seed = await _seedRepository.get(wallet.masterFingerprint);
    final root = Bip32Keys.fromSeed(seed.bytes);
    final cache = <String, Bip32Keys>{};
    final addressToKey = <String, Bip32Keys>{};

    for (final utxo in walletUtxos.whereType<BitcoinWalletUtxo>()) {
      if (utxo.isFrozen || utxo.address.isEmpty) continue;
      final key = _findKeyForUtxo(
        root: root,
        wallet: wallet,
        utxo: utxo,
        cache: cache,
      );
      if (key != null) {
        addressToKey[utxo.address] = key;
      }
    }

    final keys = <Bip32Keys>[];
    for (var i = 0; i < fundingInputSighashesHex.length; i++) {
      Bip32Keys? inputKey;
      if (i < fundingInputAddresses.length) {
        final address = fundingInputAddresses[i].trim();
        if (address.isNotEmpty) {
          inputKey = addressToKey[address];
          inputKey ??= await _findKeyForAddress(
            root: root,
            wallet: wallet,
            address: address,
            cache: cache,
          );
        }
      }
      if (inputKey == null && i < fundingInputOutpoints.length) {
        final outpoint = fundingInputOutpoints[i].trim();
        if (outpoint.isNotEmpty) {
          inputKey = _findKeyForOutpoint(
            root: root,
            wallet: wallet,
            outpoint: outpoint,
            walletUtxos: walletUtxos,
            cache: cache,
          );
        }
      }
      if (inputKey == null) {
        throw Exception(
          'No private key for DLC funding input ${i + 1} of '
          '${fundingInputSighashesHex.length}. Sync wallet UTXOs and retry.',
        );
      }
      keys.add(inputKey);
    }
    return keys;
  }

  Bip32Keys? _findKeyForOutpoint({
    required Bip32Keys root,
    required Wallet wallet,
    required String outpoint,
    required List<WalletUtxo> walletUtxos,
    required Map<String, Bip32Keys> cache,
  }) {
    final parts = outpoint.split(':');
    if (parts.length != 2) return null;
    final txid = parts[0].toLowerCase();
    final vout = int.tryParse(parts[1]);
    if (vout == null) return null;

    for (final utxo in walletUtxos.whereType<BitcoinWalletUtxo>()) {
      if (utxo.txId.toLowerCase() != txid || utxo.vout != vout) continue;
      return _findKeyForUtxo(
        root: root,
        wallet: wallet,
        utxo: utxo,
        cache: cache,
      );
    }
    return null;
  }

  Future<Bip32Keys?> _findKeyForAddress({
    required Bip32Keys root,
    required Wallet wallet,
    required String address,
    required Map<String, Bip32Keys> cache,
  }) async {
    for (final chain in [0, 1]) {
      for (var index = 0; index < 1000; index++) {
        final path = '${wallet.derivationPath}/$chain/$index';
        final key = cache.putIfAbsent(path, () => root.derivePath(path));
        final script = _scriptPubkeyForWalletKey(wallet, key);
        final derived = await AddressScriptConversions.bitcoinAddressFromScriptPubkey(
          script,
          isTestnet: wallet.isTestnet,
        );
        if (derived == address) return key;
      }
    }
    return null;
  }

  Bip32Keys? _findKeyForUtxo({
    required Bip32Keys root,
    required Wallet wallet,
    required BitcoinWalletUtxo utxo,
    required Map<String, Bip32Keys> cache,
  }) {
    final chain = utxo.addressKeyChain == WalletAddressKeyChain.internal
        ? 1
        : 0;
    for (var index = 0; index < 1000; index++) {
      final path = '${wallet.derivationPath}/$chain/$index';
      final key = cache.putIfAbsent(path, () => root.derivePath(path));
      if (_bytesEqual(
        _scriptPubkeyForWalletKey(wallet, key),
        utxo.scriptPubkey,
      )) {
        return key;
      }
    }
    return null;
  }

  Uint8List _scriptPubkeyForWalletKey(Wallet wallet, Bip32Keys key) {
    final pubkeyHash = _hash160(key.public);
    switch (wallet.scriptType) {
      case ScriptType.bip84:
        return Uint8List.fromList([0x00, 0x14, ...pubkeyHash]);
      case ScriptType.bip49:
        final redeemScript = [0x00, 0x14, ...pubkeyHash];
        final scriptHash = _hash160(redeemScript);
        return Uint8List.fromList([0xa9, 0x14, ...scriptHash, 0x87]);
      case ScriptType.bip44:
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
    final sha = sha256.convert(bytes).bytes;
    return RIPEMD160Digest().process(Uint8List.fromList(sha));
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Bip32Keys _deriveDlcKey({
    required Uint8List seedBytes,
    required String derivationPath,
  }) {
    final root = Bip32Keys.fromSeed(seedBytes);
    return root.derivePath(derivationPath);
  }

  Bip32Keys _deriveWalletAccountKey({
    required Uint8List seedBytes,
    required Wallet wallet,
  }) {
    final root = Bip32Keys.fromSeed(seedBytes);
    // This key corresponds to the wallet xpub and is used for auth nonce proof.
    return root.derivePath(wallet.derivationPath);
  }

}
