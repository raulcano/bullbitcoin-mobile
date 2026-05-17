import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_constants.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_scalar.dart';
import 'package:bb_mobile/core/dlc/data/crypto/tagged_hash.dart';
import 'package:bb_mobile/core/dlc/data/models/oracle_announcement_model.dart';

Uint8List encodeOutcomeValue(int value) {
  final normalized = value.toString();
  return Uint8List.fromList(utf8.encode(normalized));
}

Secp256k1Point computeAdaptorPoint({
  required List<int> compressedDigits,
  required XOnlyPubKeyModel oraclePublicKey,
  required List<XOnlyPubKeyModel> oracleNonces,
  required bool isSigned,
}) {
  if (compressedDigits.isEmpty) {
    throw ArgumentError('compressed_digits must not be empty');
  }

  final rPoints = isSigned ? oracleNonces.skip(1) : oracleNonces;
  if (rPoints.length < compressedDigits.length) {
    throw ArgumentError('Not enough oracle nonces for compressed digits');
  }

  final pOracle = Secp256k1Point.fromCompressed(oraclePublicKey.toCompressedPoint());
  var y = Secp256k1Point.infinity;

  for (var i = 0; i < compressedDigits.length; i++) {
    final rI = Secp256k1Point.fromCompressed(rPoints.elementAt(i).toCompressedPoint());
    final encodedDigit = encodeOutcomeValue(compressedDigits[i]);
    final mI = taggedHashScalar(oracleAttestationTag, encodedDigit);
    final mIBytes = scalarToBytes32(mI);
    final challengeData = Uint8List.fromList([
      ...rI.xonlyBytes(),
      ...pOracle.xonlyBytes(),
      ...mIBytes,
    ]);
    final eI = taggedHashScalar(bip340ChallengeTag, challengeData);
    y = y + (rI + pOracle.multiply(eI));
  }

  return y;
}

/// Per-nonce map of digit → contribution point `R_i + e_i * P_oracle`.
typedef AdaptorPointComponentCache = List<Map<int, Secp256k1Point>>;

AdaptorPointComponentCache buildAdaptorPointComponentCache({
  required XOnlyPubKeyModel oraclePublicKey,
  required List<XOnlyPubKeyModel> oracleNonces,
  required bool isSigned,
}) {
  final rPoints = isSigned ? oracleNonces.skip(1) : oracleNonces;
  final pOracle = Secp256k1Point.fromCompressed(oraclePublicKey.toCompressedPoint());
  final pOracleXonly = pOracle.xonlyBytes();

  final cache = <Map<int, Secp256k1Point>>[];
  for (final rNonce in rPoints) {
    final rI = Secp256k1Point.fromCompressed(rNonce.toCompressedPoint());
    final challengePrefix = Uint8List.fromList([
      ...rI.xonlyBytes(),
      ...pOracleXonly,
    ]);
    final digitContributions = <int, Secp256k1Point>{};
    for (var digit = 0; digit < 10; digit++) {
      final encodedDigit = encodeOutcomeValue(digit);
      final mI = taggedHashScalar(oracleAttestationTag, encodedDigit);
      final mIBytes = scalarToBytes32(mI);
      final eI = taggedHashScalar(
        bip340ChallengeTag,
        Uint8List.fromList([...challengePrefix, ...mIBytes]),
      );
      digitContributions[digit] = rI + pOracle.multiply(eI);
    }
    cache.add(digitContributions);
  }
  return cache;
}

Secp256k1Point computeAdaptorPointFromCache({
  required List<int> compressedDigits,
  required AdaptorPointComponentCache cache,
}) {
  if (compressedDigits.isEmpty) {
    throw ArgumentError('compressed_digits must not be empty');
  }
  if (cache.length < compressedDigits.length) {
    throw ArgumentError('Not enough cached nonce contributions');
  }

  var y = Secp256k1Point.infinity;
  for (var i = 0; i < compressedDigits.length; i++) {
    final digit = compressedDigits[i];
    final contribution = cache[i][digit];
    if (contribution == null) {
      throw ArgumentError("Unsupported digit '$digit' for adaptor-point cache");
    }
    y = y + contribution;
  }
  return y;
}
