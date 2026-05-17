import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_scalar.dart';
import 'package:crypto/crypto.dart' as crypto;

final Map<String, Uint8List> _tagPrefixCache = {};

Uint8List tagHash(String tag) {
  return Uint8List.fromList(crypto.sha256.convert(utf8.encode(tag)).bytes);
}

Uint8List taggedHashPrefix(String tag) {
  return _tagPrefixCache.putIfAbsent(tag, () {
    final hash = tagHash(tag);
    return Uint8List.fromList([...hash, ...hash]);
  });
}

/// BIP340-style tagged hash (32-byte digest).
Uint8List taggedHashBytes(String tag, Uint8List data) {
  final prefix = taggedHashPrefix(tag);
  return Uint8List.fromList(
    crypto.sha256.convert(Uint8List.fromList([...prefix, ...data])).bytes,
  );
}

/// Tagged hash reduced to a secp256k1 scalar.
BigInt taggedHashScalar(String tag, Uint8List data) {
  return scalarFromBytes(taggedHashBytes(tag, data));
}

/// `H(tag, x) = scalar(SHA256(tag || x))` used by DLEQ (not BIP340 tagged hash).
BigInt hScalar(Uint8List x, Uint8List tag) {
  return scalarFromBytes(
    Uint8List.fromList(crypto.sha256.convert(Uint8List.fromList([...tag, ...x])).bytes),
  );
}
