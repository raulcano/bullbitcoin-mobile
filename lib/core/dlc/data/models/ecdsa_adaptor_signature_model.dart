import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_constants.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_scalar.dart';
import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';

class EcdsaAdaptorSignatureModel {
  final Secp256k1Point r;
  final Secp256k1Point ra;
  final BigInt sA;
  final Uint8List proof;

  EcdsaAdaptorSignatureModel({
    required this.r,
    required this.ra,
    required this.sA,
    required this.proof,
  }) {
    if (r.isInfinity || ra.isInfinity) {
      throw InvalidPointException('R and R_a cannot be point at infinity');
    }
    if (sA < BigInt.zero || sA >= secp256k1Order) {
      throw InvalidAdaptorSignatureWireException('s_a out of range');
    }
    if (proof.length != 64) {
      throw InvalidAdaptorSignatureWireException('proof must be 64 bytes');
    }
  }

  /// DLC wire: `R(33) || s_a(32) || R_a(33) || proof(64)`.
  Uint8List serializeWire() {
    return Uint8List.fromList([
      ...r.toCompressed(),
      ...scalarToBytes32(sA),
      ...ra.toCompressed(),
      ...proof,
    ]);
  }

  /// Primitive layout: `R || R_a || s_a || proof`.
  Uint8List toEncryptedAdaptorBytes() {
    return Uint8List.fromList([
      ...r.toCompressed(),
      ...ra.toCompressed(),
      ...scalarToBytes32(sA),
      ...proof,
    ]);
  }

  factory EcdsaAdaptorSignatureModel.deserializeWire(Uint8List data) {
    if (data.length != kWireCetAdaptorEntryBytes) {
      throw InvalidAdaptorSignatureWireException(
        'wire must be $kWireCetAdaptorEntryBytes bytes, got ${data.length}',
      );
    }
    final r = Secp256k1Point.fromCompressed(data.sublist(0, 33));
    final sA = scalarFromBytes(data.sublist(33, 65));
    final ra = Secp256k1Point.fromCompressed(data.sublist(65, 98));
    final proof = data.sublist(98);
    return EcdsaAdaptorSignatureModel(r: r, ra: ra, sA: sA, proof: proof);
  }

  factory EcdsaAdaptorSignatureModel.fromEncryptedAdaptorBytes(Uint8List data) {
    if (data.length != kEncryptedAdaptorTotalBytes) {
      throw InvalidAdaptorSignatureWireException(
        'encrypted adaptor must be $kEncryptedAdaptorTotalBytes bytes',
      );
    }
    final r = Secp256k1Point.fromCompressed(data.sublist(0, 33));
    final ra = Secp256k1Point.fromCompressed(data.sublist(33, 66));
    final sA = scalarFromBytes(data.sublist(66, 98));
    final proof = data.sublist(98);
    return EcdsaAdaptorSignatureModel(r: r, ra: ra, sA: sA, proof: proof);
  }
}
