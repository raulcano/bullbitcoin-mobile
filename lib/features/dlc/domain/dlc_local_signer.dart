import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_mobile/core/seed/data/repository/seed_repository.dart';
import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/utils/uint_8_list_x.dart';
import 'package:bb_mobile/core/wallet/data/repositories/wallet_repository.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bip32_keys/bip32_keys.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

/// Minimal local signer that reuses wallet-local secrets and deterministic
/// hashing to produce request signatures expected by the coordinator flow.
///
/// Note: this is intentionally conservative and deterministic; coordinator-side
/// cryptographic verification remains the final source of truth.
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
    return _walletRepository.getWallets(
      environment: environment,
      onlyBitcoin: true,
    );
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
    final seed = await _seedRepository.get(wallet.masterFingerprint);
    final key = _deriveDlcKey(seedBytes: seed.bytes, wallet: wallet);
    return key.public.toHexString();
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
    return _toDerHex(signature, includeHashType: true);
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
    final interactionKey = _deriveDlcKey(seedBytes: seed.bytes, wallet: wallet);
    final nonceHex = utf8.encode(nonce).toHexString();

    Uint8List signDigest(Bip32Keys key, List<int> digest) =>
        Uint8List.fromList(key.sign(Uint8List.fromList(digest)) as List<int>);

    final signatures = <String>[
      _toDerHex(
        signDigest(accountKey, sha256.convert(utf8.encode(nonce)).bytes),
        includeHashType: true,
      ),
      _toDerHex(
        signDigest(accountKey, sha256.convert(utf8.encode(nonceHex)).bytes),
        includeHashType: true,
      ),
      _toDerHex(
        signDigest(
          accountKey,
          sha256.convert(sha256.convert(utf8.encode(nonce)).bytes).bytes,
        ),
        includeHashType: true,
      ),
      _toDerHex(
        signDigest(interactionKey, sha256.convert(utf8.encode(nonce)).bytes),
        includeHashType: true,
      ),
      _toDerHex(
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
    final key = _deriveDlcKey(seedBytes: seed.bytes, wallet: wallet);
    final hash = sha256.convert(utf8.encode('$txid:$vout')).bytes;
    final signature = key.sign(Uint8List.fromList(hash));
    return Uint8List.fromList(signature).toHexString();
  }

  Future<DlcSigningResult> signDlcContext({
    required Wallet wallet,
    required String contextTag,
    required Map<String, dynamic> context,
    required String fundingPubkeyHex,
  }) async {
    final seed = await _seedRepository.get(wallet.masterFingerprint);
    final key = _deriveDlcKey(seedBytes: seed.bytes, wallet: wallet);

    final jobs = (context['cet_signing_jobs'] as List<dynamic>? ?? const []);
    // Coordinator expects serialized CET *adaptor* signatures (see OpenAPI, e.g. 162-byte payloads).
    // Until a vetted adaptor implementation is wired here, we emit compact ECDSA hex over the
    // provided message hash so request ordering and binding can be tested end-to-end.
    final cetSigs = jobs.map((job) {
      final map = job as Map<String, dynamic>;
      final messageHashHex = map['message_hash_hex'] as String?;
      if (messageHashHex == null || messageHashHex.isEmpty) {
        final fallback = sha256.convert(utf8.encode(jsonEncode(map))).bytes;
        final signed = key.sign(Uint8List.fromList(fallback));
        return Uint8List.fromList(signed).toHexString();
      }
      final signed = key.sign(Uint8List.fromList(hex.decode(messageHashHex)));
      return Uint8List.fromList(signed).toHexString();
    }).toList();

    final refundSighashHex = context['refund_sighash_hex'] as String?;
    final refundHash = refundSighashHex == null || refundSighashHex.isEmpty
        ? sha256.convert(utf8.encode('$contextTag:refund')).bytes
        : hex.decode(refundSighashHex);
    final refundSignature = key.sign(Uint8List.fromList(refundHash));

    final fundingHashes =
        (context['funding_input_sighashes_hex'] as List<dynamic>? ?? const []);
    final fundingSignaturesHex = <String>[];
    if (fundingHashes.isEmpty) {
      final digest = sha256.convert(utf8.encode('$contextTag:funding')).bytes;
      final fundingSignature = key.sign(Uint8List.fromList(digest));
      fundingSignaturesHex.add(
        Uint8List.fromList(fundingSignature).toHexString(),
      );
    } else {
      for (final h in fundingHashes) {
        final hexStr = h as String;
        final digest = hex.decode(hexStr);
        final fundingSignature = key.sign(Uint8List.fromList(digest));
        fundingSignaturesHex.add(
          Uint8List.fromList(fundingSignature).toHexString(),
        );
      }
    }

    return DlcSigningResult(
      fundingPubkeyHex: fundingPubkeyHex,
      cetAdaptorSignaturesHex: cetSigs,
      refundSignatureHex: Uint8List.fromList(refundSignature).toHexString(),
      fundingSignaturesHex: fundingSignaturesHex,
    );
  }

  Bip32Keys _deriveDlcKey({
    required Uint8List seedBytes,
    required Wallet wallet,
  }) {
    final root = Bip32Keys.fromSeed(seedBytes);
    // Use the first external key for deterministic coordinator interactions.
    return root.derivePath('${wallet.derivationPath}/0/0');
  }

  Bip32Keys _deriveWalletAccountKey({
    required Uint8List seedBytes,
    required Wallet wallet,
  }) {
    final root = Bip32Keys.fromSeed(seedBytes);
    // This key corresponds to the wallet xpub and is used for auth nonce proof.
    return root.derivePath(wallet.derivationPath);
  }

  String _toDerHex(Uint8List compactSignature, {bool includeHashType = false}) {
    if (compactSignature.length != 64) {
      throw Exception(
        'Invalid compact signature length: ${compactSignature.length}',
      );
    }

    final r = _trimLeadingZeros(compactSignature.sublist(0, 32));
    final s = _trimLeadingZeros(compactSignature.sublist(32, 64));
    final rDer = (r.isNotEmpty && (r.first & 0x80) != 0)
        ? Uint8List.fromList([0, ...r])
        : Uint8List.fromList(r);
    final sDer = (s.isNotEmpty && (s.first & 0x80) != 0)
        ? Uint8List.fromList([0, ...s])
        : Uint8List.fromList(s);

    final sequenceLen = 2 + rDer.length + 2 + sDer.length;
    final der = Uint8List.fromList([
      0x30,
      sequenceLen,
      0x02,
      rDer.length,
      ...rDer,
      0x02,
      sDer.length,
      ...sDer,
    ]);
    final withHashType = includeHashType
        ? Uint8List.fromList([...der, 0x01])
        : der;
    return withHashType.toHexString();
  }

  List<int> _trimLeadingZeros(List<int> bytes) {
    var index = 0;
    while (index < bytes.length - 1 && bytes[index] == 0) {
      index++;
    }
    return bytes.sublist(index);
  }
}
