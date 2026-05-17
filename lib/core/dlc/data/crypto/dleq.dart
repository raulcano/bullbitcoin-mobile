import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/nonce_generator.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_constants.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_scalar.dart';
import 'package:bb_mobile/core/dlc/data/crypto/tagged_hash.dart';
import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';

final Uint8List dleqTagPrefix = taggedHashPrefix(dleqTagInput);

Uint8List dleqProve(
  BigInt witness,
  Secp256k1Point x,
  Secp256k1Point y,
  Secp256k1Point z,
) {
  if (witness % secp256k1Order == BigInt.zero) {
    throw InvalidDleqProofException('witness cannot be zero');
  }
  if (x.isInfinity || y.isInfinity || z.isInfinity) {
    throw InvalidDleqProofException('points cannot be at infinity');
  }

  final witnessBytes = scalarToBytes32(witness % secp256k1Order);
  final nonceInput = Uint8List.fromList([
    ...dleqTagPrefix,
    ...x.toCompressed(),
    ...y.toCompressed(),
    ...z.toCompressed(),
    ...witnessBytes,
  ]);
  final a = sampleNonce(nonceInput) % secp256k1Order;
  final aG = Secp256k1Point.generator().multiply(a);
  final aY = y.multiply(a);

  final challengeInput = Uint8List.fromList([
    ...x.toCompressed(),
    ...y.toCompressed(),
    ...z.toCompressed(),
    ...aG.toCompressed(),
    ...aY.toCompressed(),
  ]);
  final b = hScalar(challengeInput, dleqTagPrefix);
  final c = (a + b * witness) % secp256k1Order;

  return Uint8List.fromList([...scalarToBytes32(b), ...scalarToBytes32(c)]);
}

bool dleqVerify(
  Secp256k1Point x,
  Secp256k1Point y,
  Secp256k1Point z,
  Uint8List proof,
) {
  if (x.isInfinity || y.isInfinity || z.isInfinity) {
    throw InvalidDleqProofException('points cannot be at infinity');
  }
  if (proof.length != 64) {
    throw InvalidDleqProofException('proof must be 64 bytes');
  }

  final b = scalarFromBytes(proof.sublist(0, 32));
  final c = scalarFromBytes(proof.sublist(32, 64));

  final bX = x.multiply(b);
  final aG = Secp256k1Point.generator().multiply(c) + bX.negate();
  final bZ = z.multiply(b);
  final aY = y.multiply(c) + bZ.negate();

  final challengeInput = Uint8List.fromList([
    ...x.toCompressed(),
    ...y.toCompressed(),
    ...z.toCompressed(),
    ...aG.toCompressed(),
    ...aY.toCompressed(),
  ]);
  final impliedB = hScalar(challengeInput, dleqTagPrefix) % secp256k1Order;
  return impliedB == b;
}
