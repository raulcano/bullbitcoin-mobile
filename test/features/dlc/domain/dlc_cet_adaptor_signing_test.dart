import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/ecdsa_adaptor.dart';
import 'package:bb_mobile/core/dlc/data/crypto/nonce_generator.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_constants.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/data/models/ecdsa_adaptor_signature_model.dart';
import 'package:bb_mobile/core/utils/uint_8_list_x.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_cet_adaptor_signing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('produces 162-byte wire hex per coordinator job', () {
    testNonceOverride = (_) => BigInt.parse('9007199254740991');

    final priv = Uint8List.fromList(List.filled(32, 0x11));
    var scalar = BigInt.zero;
    for (final b in priv) {
      scalar = (scalar << 8) | BigInt.from(b);
    }
    final pub = Secp256k1Point.generator().multiply(scalar).toCompressed();

    final messageHash = Uint8ListX.fromHexString(
      '8131e6f4b45754f2c90bd06688ceeabc0c45055460729928b4eecf11026a9e2d',
    );
    final y = Secp256k1Point.fromCompressed(
      Uint8ListX.fromHexString(
        '0324afa2587b3965c4132a135c63ff5a8cc932e1cedda1c4f9c2858c24b34039ae',
      ),
    );

    final adaptorSig = adaptorEncrypt(
      privateKey: priv,
      adaptorPoint: y,
      messageHash: messageHash,
    );
    final expectedHex = adaptorSig.serializeWire().toHexString();

    final fromHelper = signCetAdaptorJobsFromCoordinatorContext(
      cetSigningJobs: [
        {
          'message_hash_hex': messageHash.toHexString(),
          'adaptor_point_hex': y.toCompressed().toHexString(),
        },
      ],
      fundingPrivateKey: priv,
    );

    expect(fromHelper, hasLength(1));
    expect(fromHelper.first.length, 324);
    expect(fromHelper.first, expectedHex);

    final parsed = EcdsaAdaptorSignatureModel.deserializeWire(
      Uint8ListX.fromHexString(fromHelper.first),
    );
    expect(parsed.toEncryptedAdaptorBytes().length, kEncryptedAdaptorTotalBytes);

    expect(
      adaptorVerify(
        signerPublicKey: Secp256k1Point.fromCompressed(pub),
        adaptorPoint: y,
        messageHash: messageHash,
        encryptedAdaptorBytes: parsed.toEncryptedAdaptorBytes(),
      ),
      isTrue,
    );

    testNonceOverride = null;
  });

  test('rejects job missing adaptor_point_hex', () {
    expect(
      () => signCetAdaptorJobsFromCoordinatorContext(
        cetSigningJobs: [
          {'message_hash_hex': '00' * 64},
        ],
        fundingPrivateKey: Uint8List.fromList(List.filled(32, 1)),
      ),
      throwsArgumentError,
    );
  });
}
