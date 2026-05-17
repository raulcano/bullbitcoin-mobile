import 'dart:math';
import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_constants.dart';
import 'package:bb_mobile/core/dlc/data/crypto/tagged_hash.dart';

/// Optional override for deterministic tests (`data || random` is still hashed).
typedef NonceFunction = BigInt Function(Uint8List data);

NonceFunction? testNonceOverride;

/// `scalar(SHA256(data || random_32))` per `helpers_ecdsa.nonce`.
BigInt sampleNonce(Uint8List data) {
  if (testNonceOverride != null) {
    return testNonceOverride!(data) % secp256k1Order;
  }
  final random = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    random[i] = Random.secure().nextInt(256);
  }
  return hScalar(Uint8List.fromList([...data, ...random]), Uint8List(0));
}

/// Derive adaptor signing nonce *k* from `comp(Y) || messageHash || x`.
BigInt adaptorSigningNonce({
  required Uint8List yCompressed,
  required Uint8List messageHash,
  required Uint8List privateKey,
}) {
  if (messageHash.length != 32) {
    throw ArgumentError('messageHash must be 32 bytes');
  }
  if (privateKey.length != 32) {
    throw ArgumentError('privateKey must be 32 bytes');
  }
  var k = BigInt.zero;
  var salt = Uint8List(0);
  while (k == BigInt.zero) {
    final input = Uint8List.fromList([
      ...yCompressed,
      ...messageHash,
      ...privateKey,
      ...salt,
    ]);
    k = sampleNonce(input);
    salt = Uint8List.fromList([...salt, 0]);
  }
  return k;
}
