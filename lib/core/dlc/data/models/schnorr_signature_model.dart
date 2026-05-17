import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_constants.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_scalar.dart';
import 'package:bb_mobile/core/dlc/data/crypto/tagged_hash.dart';
import 'package:bb_mobile/core/dlc/data/models/ecdsa_signature_model.dart';
import 'package:bb_mobile/core/dlc/data/models/oracle_announcement_model.dart';
import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';

class SchnorrSignatureModel {
  final Uint8List r;
  final Uint8List s;

  SchnorrSignatureModel({required this.r, required this.s}) {
    if (r.length != 32 || s.length != 32) {
      throw InvalidAdaptorSignatureWireException('Schnorr r and s must be 32 bytes');
    }
  }

  Uint8List serialize() => Uint8List.fromList([...r, ...s]);

  factory SchnorrSignatureModel.deserialize(Uint8List data) {
    if (data.length != 64) {
      throw InvalidAdaptorSignatureWireException('Schnorr signature must be 64 bytes');
    }
    return SchnorrSignatureModel(r: data.sublist(0, 32), s: data.sublist(32));
  }

  factory SchnorrSignatureModel.fromHex(String hex) {
    return SchnorrSignatureModel.deserialize(EcdsaSignatureModel.fromHex(hex).serialize());
  }

  factory SchnorrSignatureModel.fromCompact(EcdsaSignatureModel signature) {
    return SchnorrSignatureModel(r: signature.r, s: signature.s);
  }

  bool verify(XOnlyPubKeyModel publicKey, Uint8List message) {
    if (message.length != 32) {
      throw ArgumentError('Schnorr verification expects a 32-byte message');
    }
    final pubkey = Secp256k1Point.fromXOnly(publicKey.bytes);
    final sInt = scalarFromBytes(s);
    final challengeData = Uint8List.fromList([
      ...r,
      ...publicKey.bytes,
      ...message,
    ]);
    final challenge = taggedHashScalar(bip340ChallengeTag, challengeData);
    final impliedR =
        Secp256k1Point.generator().multiply(sInt) + pubkey.multiply(challenge).negate();
    if (impliedR.isInfinity) return false;
    if (impliedR.xonlyBytes().equals(r) == false) return false;
    return impliedR.xCoordinate.isEven;
  }
}

extension _Uint8ListEquals on Uint8List {
  bool equals(Uint8List other) {
    if (length != other.length) return false;
    for (var i = 0; i < length; i++) {
      if (this[i] != other[i]) return false;
    }
    return true;
  }
}
