import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/dleq.dart';
import 'package:bb_mobile/core/dlc/data/crypto/ecdsa_adaptor.dart';
import 'package:bb_mobile/core/dlc/data/crypto/low_s.dart';
import 'package:bb_mobile/core/dlc/data/crypto/nonce_generator.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_constants.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_scalar.dart';
import 'package:bb_mobile/core/dlc/data/crypto/tagged_hash.dart';
import 'package:bb_mobile/core/dlc/data/models/ecdsa_adaptor_signature_model.dart';
import 'package:bb_mobile/core/dlc/data/models/ecdsa_signature_model.dart';
import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String hex) {
  final cleaned = hex.replaceAll(' ', '');
  return Uint8List.fromList(
    List.generate(cleaned.length ~/ 2, (i) {
      return int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
    }),
  );
}

void main() {
  group('tagged hash', () {
    test('BIP340 challenge prefix is 64 bytes', () {
      final prefix = taggedHashPrefix(bip340ChallengeTag);
      expect(prefix.length, 64);
    });
  });

  group('DLEQ', () {
    test('round-trip', () {
      final k = BigInt.parse('12345');
      final y = Secp256k1Point.fromCompressed(
        _hex('024eee18be9a5a5224000f916c80b393447989e7194bc0b0f1ad7a03369702bb51'),
      );
      final x = Secp256k1Point.generator().multiply(k);
      final z = y.multiply(k);
      final proof = dleqProve(k, x, y, z);
      expect(dleqVerify(x, y, z, proof), isTrue);
    });

    test('tampered proof fails', () {
      final k = BigInt.parse('99');
      final y = Secp256k1Point.generator().multiply(BigInt.from(3));
      final x = Secp256k1Point.generator().multiply(k);
      final z = y.multiply(k);
      final proof = dleqProve(k, x, y, z);
      proof[0] ^= 0x01;
      expect(dleqVerify(x, y, z, proof), isFalse);
    });
  });

  group('ecdsa adaptor vectors', () {
    late List<dynamic> vectors;

    setUpAll(() {
      final file = File('test/core/dlc/fixtures/ecdsa-adaptor.json');
      vectors = json.decode(file.readAsStringSync()) as List<dynamic>;
    });

    test('verification item 0', () {
      final v = vectors[0] as Map<String, dynamic>;
      final ok = adaptorVerify(
        signerPublicKey: Secp256k1Point.fromCompressed(_hex(v['public_signing_key'] as String)),
        adaptorPoint: Secp256k1Point.fromCompressed(_hex(v['encryption_key'] as String)),
        messageHash: _hex(v['message_hash'] as String),
        encryptedAdaptorBytes: _hex(v['adaptor_sig'] as String),
      );
      expect(ok, isTrue);
      final sig = adaptorDecrypt(
        encryptedAdaptorBytes: _hex(v['adaptor_sig'] as String),
        decryptionKey: _hex(v['decryption_key'] as String),
      );
      expect(sig.serialize(), _hex(v['signature'] as String));
      final y = Secp256k1Point.fromCompressed(_hex(v['encryption_key'] as String));
      expect(
        adaptorRecoverDecryptionKey(
          adaptorPoint: y,
          encryptedAdaptorBytes: _hex(v['adaptor_sig'] as String),
          signature: EcdsaSignatureModel.deserialize(_hex(v['signature'] as String)),
        ),
        _hex(v['decryption_key'] as String),
      );
    });

    test('verification item 1 (high-s path)', () {
      final v = vectors[1] as Map<String, dynamic>;
      expect(
        adaptorVerify(
          signerPublicKey: Secp256k1Point.fromCompressed(_hex(v['public_signing_key'] as String)),
          adaptorPoint: Secp256k1Point.fromCompressed(_hex(v['encryption_key'] as String)),
          messageHash: _hex(v['message_hash'] as String),
          encryptedAdaptorBytes: _hex(v['adaptor_sig'] as String),
        ),
        isTrue,
      );
      final decrypted = adaptorDecrypt(
        encryptedAdaptorBytes: _hex(v['adaptor_sig'] as String),
        decryptionKey: _hex(v['decryption_key'] as String),
      );
      expect(decrypted.serialize(), _hex(v['signature'] as String));
      final recovered = adaptorRecoverDecryptionKey(
        adaptorPoint: Secp256k1Point.fromCompressed(_hex(v['encryption_key'] as String)),
        encryptedAdaptorBytes: _hex(v['adaptor_sig'] as String),
        signature: EcdsaSignatureModel.deserialize(_hex(v['signature'] as String)),
      );
      expect(recovered, _hex(v['decryption_key'] as String));
    });

    test('invalid proof raises', () {
      final v = vectors[2] as Map<String, dynamic>;
      expect(
        () => adaptorVerify(
          signerPublicKey: Secp256k1Point.fromCompressed(_hex(v['public_signing_key'] as String)),
          adaptorPoint: Secp256k1Point.fromCompressed(_hex(v['encryption_key'] as String)),
          messageHash: _hex(v['message_hash'] as String),
          encryptedAdaptorBytes: _hex(v['adaptor_sig'] as String),
        ),
        throwsA(isA<InvalidDleqProofException>()),
      );
    });

    test('recovery item 3', () {
      final v = vectors[3] as Map<String, dynamic>;
      final recovered = adaptorRecoverDecryptionKey(
        adaptorPoint: Secp256k1Point.fromCompressed(_hex(v['encryption_key'] as String)),
        encryptedAdaptorBytes: _hex(v['adaptor_sig'] as String),
        signature: EcdsaSignatureModel.deserialize(_hex(v['signature'] as String)),
      );
      expect(recovered, _hex(v['decryption_key'] as String));
    });

    test('recovery mismatch raises', () {
      final v = vectors[4] as Map<String, dynamic>;
      expect(
        () => adaptorRecoverDecryptionKey(
          adaptorPoint: Secp256k1Point.fromCompressed(_hex(v['encryption_key'] as String)),
          encryptedAdaptorBytes: _hex(v['adaptor_sig'] as String),
          signature: EcdsaSignatureModel.deserialize(_hex(v['signature'] as String)),
        ),
        throwsA(isA<DecryptionKeyMismatchException>()),
      );
    });

    test('high-s recovery item 5', () {
      final v = vectors[5] as Map<String, dynamic>;
      final recovered = adaptorRecoverDecryptionKey(
        adaptorPoint: Secp256k1Point.fromCompressed(_hex(v['encryption_key'] as String)),
        encryptedAdaptorBytes: _hex(v['adaptor_sig'] as String),
        signature: EcdsaSignatureModel.deserialize(_hex(v['signature'] as String)),
      );
      expect(recovered, _hex(v['decryption_key'] as String));
    });
  });

  group('wire codec', () {
    test('serializeWire round-trip', () {
      final k = BigInt.parse('1234567890123456789012345678901234567890123456789') % secp256k1Order;
      final y = Secp256k1Point.generator().multiply(BigInt.from(3));
      final ra = Secp256k1Point.generator().multiply(k);
      final r = y.multiply(k);
      final proof = dleqProve(k, ra, y, r);
      final original = EcdsaAdaptorSignatureModel(
        r: r,
        ra: ra,
        sA: BigInt.from(42) % secp256k1Order,
        proof: proof,
      );
      final wire = original.serializeWire();
      expect(wire.length, kWireCetAdaptorEntryBytes);
      final back = EcdsaAdaptorSignatureModel.deserializeWire(wire);
      expect(back.serializeWire(), wire);
      expect(back.toEncryptedAdaptorBytes(), original.toEncryptedAdaptorBytes());
    });

    test('primitive layout order differs from wire', () {
      final k = BigInt.from(7);
      final y = Secp256k1Point.generator().multiply(BigInt.from(5));
      final ra = Secp256k1Point.generator().multiply(k);
      final r = y.multiply(k);
      final proof = dleqProve(k, ra, y, r);
      final sig = EcdsaAdaptorSignatureModel(
        r: r,
        ra: ra,
        sA: BigInt.from(11),
        proof: proof,
      );
      final wire = sig.serializeWire();
      final enc = sig.toEncryptedAdaptorBytes();
      expect(wire.sublist(0, 33), enc.sublist(0, 33));
      expect(wire.sublist(33, 65), enc.sublist(66, 98));
      expect(wire.sublist(65, 98), enc.sublist(33, 66));
    });
  });

  group('low-S', () {
    test('normalizes high s on decrypt path', () {
      final highS = bip62HighSMax + BigInt.one;
      expect(isHighS(highS), isTrue);
      final low = normalizeToLowS(highS);
      expect(isHighS(low), isFalse);
    });
  });

  group('bad inputs', () {
    test('zero private key', () {
      expect(
        () => adaptorEncrypt(
          privateKey: Uint8List(32),
          adaptorPoint: Secp256k1Point.generator(),
          messageHash: _hex('00' * 32),
        ),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });

    test('invalid wire length', () {
      expect(
        () => EcdsaAdaptorSignatureModel.deserializeWire(Uint8List(10)),
        throwsA(isA<InvalidAdaptorSignatureWireException>()),
      );
    });
  });

  tearDown(() {
    testNonceOverride = null;
  });
}
