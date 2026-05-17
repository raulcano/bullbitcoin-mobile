import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';

class EcdsaSignatureModel {
  final Uint8List r;
  final Uint8List s;

  EcdsaSignatureModel({required this.r, required this.s}) {
    if (r.length != 32 || s.length != 32) {
      throw InvalidAdaptorSignatureWireException('ECDSA r and s must be 32 bytes');
    }
  }

  Uint8List serialize() => Uint8List.fromList([...r, ...s]);

  factory EcdsaSignatureModel.deserialize(Uint8List data) {
    if (data.length != 64) {
      throw InvalidAdaptorSignatureWireException('ECDSA signature must be 64 bytes');
    }
    return EcdsaSignatureModel(r: data.sublist(0, 32), s: data.sublist(32));
  }

  factory EcdsaSignatureModel.fromHex(String hex) {
    final cleaned = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (cleaned.length != 128) {
      throw InvalidAdaptorSignatureWireException('ECDSA hex must be 128 characters');
    }
    final bytes = Uint8List(64);
    for (var i = 0; i < 64; i++) {
      bytes[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return EcdsaSignatureModel.deserialize(bytes);
  }
}
