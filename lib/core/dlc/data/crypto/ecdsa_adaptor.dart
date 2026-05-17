import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/dleq.dart';
import 'package:bb_mobile/core/dlc/data/crypto/low_s.dart';
import 'package:bb_mobile/core/dlc/data/crypto/nonce_generator.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_constants.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_scalar.dart';
import 'package:bb_mobile/core/dlc/data/models/ecdsa_adaptor_signature_model.dart';
import 'package:bb_mobile/core/dlc/data/models/ecdsa_signature_model.dart';
import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';

EcdsaAdaptorSignatureModel adaptorEncrypt({
  required Uint8List privateKey,
  required Secp256k1Point adaptorPoint,
  required Uint8List messageHash,
}) {
  if (privateKey.length != 32 || isZeroScalarBytes(privateKey)) {
    throw InvalidPrivateKeyException('must be 32 non-zero bytes');
  }
  if (messageHash.length != 32) {
    throw ArgumentError('messageHash must be 32 bytes');
  }
  if (adaptorPoint.isInfinity) {
    throw InvalidPointException('adaptor point cannot be infinity');
  }

  final yCompressed = adaptorPoint.toCompressed();
  final k = adaptorSigningNonce(
    yCompressed: yCompressed,
    messageHash: messageHash,
    privateKey: privateKey,
  );

  final rA = Secp256k1Point.generator().multiply(k);
  final r = adaptorPoint.multiply(k);
  if (r.isInfinity || rA.isInfinity) {
    throw InvalidPointException('nonce points must not be at infinity');
  }

  final rScalar = r.xModN();
  final m = scalarFromBytes(messageHash);
  final xScalar = scalarFromBytes(privateKey);
  final sA = (modInverse(k) * (m + rScalar * xScalar)) % secp256k1Order;
  final proof = dleqProve(k, rA, adaptorPoint, r);

  return EcdsaAdaptorSignatureModel(
    r: r,
    ra: rA,
    sA: sA,
    proof: proof,
  );
}

bool adaptorVerify({
  required Secp256k1Point signerPublicKey,
  required Secp256k1Point adaptorPoint,
  required Uint8List messageHash,
  required Uint8List encryptedAdaptorBytes,
}) {
  if (messageHash.length != 32) {
    throw ArgumentError('messageHash must be 32 bytes');
  }
  if (encryptedAdaptorBytes.length != kEncryptedAdaptorTotalBytes) {
    throw InvalidAdaptorSignatureWireException(
      'expected $kEncryptedAdaptorTotalBytes bytes',
    );
  }

  final parsed = _parseEncryptedAdaptorBytes(encryptedAdaptorBytes);
  if (!dleqVerify(parsed.ra, adaptorPoint, parsed.r, parsed.proof)) {
    throw InvalidDleqProofException('proof is wrong');
  }

  final m = scalarFromBytes(messageHash) % secp256k1Order;
  final r = parsed.r.xModN();
  final u1 = (modInverse(parsed.sA) * m) % secp256k1Order;
  final u2 = (modInverse(parsed.sA) * r) % secp256k1Order;
  final check = Secp256k1Point.generator().multiply(u1) + signerPublicKey.multiply(u2);
  return check == parsed.ra;
}

EcdsaSignatureModel adaptorDecrypt({
  required Uint8List encryptedAdaptorBytes,
  required Uint8List decryptionKey,
}) {
  if (encryptedAdaptorBytes.length != kEncryptedAdaptorTotalBytes) {
    throw InvalidAdaptorSignatureWireException(
      'expected $kEncryptedAdaptorTotalBytes bytes',
    );
  }
  if (decryptionKey.length != 32) {
    throw ArgumentError('decryption key must be 32 bytes');
  }

  final parsed = _parseEncryptedAdaptorBytes(encryptedAdaptorBytes);
  final y = scalarFromBytes(decryptionKey);
  var s = (parsed.sA * modInverse(y)) % secp256k1Order;
  s = normalizeToLowS(s);
  final r = parsed.r.xModN();

  return EcdsaSignatureModel(
    r: scalarToBytes32(r),
    s: scalarToBytes32(s),
  );
}

Uint8List adaptorRecoverDecryptionKey({
  required Secp256k1Point adaptorPoint,
  required Uint8List encryptedAdaptorBytes,
  required EcdsaSignatureModel signature,
}) {
  if (adaptorPoint.isInfinity) {
    throw InvalidPointException('Y cannot be point at infinity');
  }
  if (encryptedAdaptorBytes.length != kEncryptedAdaptorTotalBytes) {
    throw InvalidAdaptorSignatureWireException(
      'expected $kEncryptedAdaptorTotalBytes bytes',
    );
  }

  final parsed = _parseEncryptedAdaptorBytes(encryptedAdaptorBytes);
  var rSig = scalarFromBytes(signature.r);
  var sSig = scalarFromBytes(signature.s);
  sSig = normalizeToLowS(sSig);

  final rImplied = parsed.r.xModN();
  if (rSig != rImplied) {
    throw DecryptionKeyMismatchException('the R value of the signature does not match');
  }

  final y = (modInverse(sSig) * parsed.sA) % secp256k1Order;
  final yImplied = Secp256k1Point.generator().multiply(y);

  if (yImplied == adaptorPoint) {
    return scalarToBytes32(y);
  }
  final negY = ((-y) % secp256k1Order);
  if (yImplied == adaptorPoint.negate()) {
    return scalarToBytes32(negY);
  }
  throw DecryptionKeyMismatchException('Y_implied does not match Y or -Y');
}

({Secp256k1Point r, Secp256k1Point ra, BigInt sA, Uint8List proof})
_parseEncryptedAdaptorBytes(Uint8List bytes) {
  final r = Secp256k1Point.fromCompressed(bytes.sublist(0, 33));
  final ra = Secp256k1Point.fromCompressed(bytes.sublist(33, 66));
  final sA = scalarFromBytes(bytes.sublist(66, 98));
  final proof = bytes.sublist(98);
  if (proof.length != 64) {
    throw InvalidAdaptorSignatureWireException('invalid DLEQ proof length');
  }
  return (r: r, ra: ra, sA: sA, proof: proof);
}
