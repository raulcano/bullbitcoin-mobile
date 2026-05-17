import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_constants.dart';

BigInt scalarFromBytes(Uint8List data) {
  var value = BigInt.zero;
  for (final byte in data) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value % secp256k1Order;
}

Uint8List scalarToBytes32(BigInt scalar) {
  final normalized = scalar % secp256k1Order;
  final bytes = Uint8List(32);
  var value = normalized;
  for (var i = 31; i >= 0; i--) {
    bytes[i] = (value & BigInt.from(0xff)).toInt();
    value >>= 8;
  }
  return bytes;
}

BigInt modInverse(BigInt value) {
  final normalized = value % secp256k1Order;
  if (normalized == BigInt.zero) {
    throw ArgumentError('Cannot invert zero scalar');
  }
  return normalized.modInverse(secp256k1Order);
}

bool isZeroScalarBytes(Uint8List bytes) {
  if (bytes.length != 32) return false;
  for (final b in bytes) {
    if (b != 0) return false;
  }
  return true;
}
