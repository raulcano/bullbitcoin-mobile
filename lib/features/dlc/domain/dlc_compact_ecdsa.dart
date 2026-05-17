import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

/// RFC6979-style ECDSA sign matching [bip32_keys] compact output (low-*s*, 64 bytes).
Uint8List signCompactSecp256k1({
  required Uint8List privateKey32,
  required Uint8List digest32,
}) {
  if (privateKey32.length != 32) {
    throw ArgumentError('private key must be 32 bytes');
  }
  if (digest32.length != 32) {
    throw ArgumentError('digest must be 32 bytes');
  }

  final domain = ECCurve_secp256k1();
  final signer = ECDSASigner(null, HMac(SHA256Digest(), 64));
  final privateKey = ECPrivateKey(_decodeBigInt(privateKey32), domain);
  signer.init(true, PrivateKeyParameter(privateKey));
  final sig = signer.generateSignature(digest32) as ECSignature;

  final n = domain.n;
  final nDiv2 = n >> 1;
  final s = sig.s.compareTo(nDiv2) > 0 ? n - sig.s : sig.s;

  return Uint8List.fromList([
    ..._encodeBigInt32(sig.r),
    ..._encodeBigInt32(s),
  ]);
}

BigInt _decodeBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) + BigInt.from(byte);
  }
  return result;
}

Uint8List _encodeBigInt32(BigInt value) {
  final bytes = Uint8List(32);
  var v = value;
  for (var i = 31; i >= 0; i--) {
    bytes[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return bytes;
}
