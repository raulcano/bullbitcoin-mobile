import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_mobile/core/utils/bip32_derivation.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_ecdsa_der.dart';
import 'package:bip32_keys/bip32_keys.dart';
import 'package:bip39_mnemonic/bip39_mnemonic.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _coordinatorXpubProofDigest(String nonce) {
  final messageBytes = Uint8List.fromList(utf8.encode(nonce));
  if (messageBytes.length == 32) {
    return messageBytes;
  }
  final first = sha256.convert(messageBytes).bytes;
  return Uint8List.fromList(sha256.convert(first).bytes);
}

void main() {
  test('testnet account xpub registration signature is deterministic', () {
    const words =
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    final seed = Uint8List.fromList(
      Mnemonic.fromWords(words: words.split(' ')).seed,
    );
    const path = "m/84'/1'/0'";
    const nonce =
        'fixed-nonce-for-cross-check-012345678901234567890123456789012345678901234567890';

    final root = Bip32Keys.fromSeed(seed);
    final accountKey = root.derivePath(path);
    final xpub = accountKey.neutered.convert(XpubType.vpub);
    expect(xpub.startsWith('vpub'), isTrue);

    final digest = _coordinatorXpubProofDigest(nonce);
    final compactSignature = Uint8List.fromList(
      accountKey.sign(digest) as List<int>,
    );
    final signatureHex = compactSecp256k1SignatureToDerHex(
      compactSignature,
      includeHashType: true,
    );

    // Golden values from bitcoinlib on the same seed/path/nonce.
    expect(
      xpub,
      'vpub5Y6cjg78GGuNLsaPhmYsiw4gYX3HoQiRBiSwDaBXKUafCt9bNwWQiitDk5VZ5BVxYnQdwoTyXSs2JHRPAgjAvtbBrf8ZhDYe2jWAqvZVnsc',
    );
    expect(
      signatureHex,
      '3044022057ccc56c7efccbf7eb9ad3c5112b1b1076b73f1c8e71dbcc2d0a8a67cfa89bfb022032bee7f6e1fe97d389f18b3063c5fba40317d388e5c965dfa2509995dac2569801',
    );
  });
}
