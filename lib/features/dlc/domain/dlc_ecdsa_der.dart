import 'dart:typed_data';

import 'package:bb_mobile/core/utils/uint_8_list_x.dart';

/// DER-encodes a 64-byte compact secp256k1 signature (BIP340-style r||s).
///
/// When [includeHashType] is true, appends `SIGHASH_ALL` (`0x01`). The DLC
/// coordinator's bitcoinlib verifier expects this trailing byte for registration
/// proofs (`POST /auth/wallet`); pure DER without it is mis-parsed as truncated
/// ASN.1 and fails with `InvalidDerSignature`.
String compactSecp256k1SignatureToDerHex(
  Uint8List compactSignature, {
  bool includeHashType = false,
}) {
  if (compactSignature.length != 64) {
    throw ArgumentError(
      'Compact signature must be 64 bytes, got ${compactSignature.length}',
    );
  }

  final rBody = _derIntegerBody(compactSignature.sublist(0, 32));
  final sBody = _derIntegerBody(compactSignature.sublist(32, 64));
  final inner = Uint8List.fromList([
    0x02,
    rBody.length,
    ...rBody,
    0x02,
    sBody.length,
    ...sBody,
  ]);
  final der = Uint8List.fromList([0x30, inner.length, ...inner]);
  final out = includeHashType
      ? Uint8List.fromList([...der, 0x01])
      : der;
  return out.toHexString();
}

/// Strips leading zeros, then prepends `0x00` when the high bit is set (bitcoinlib).
Uint8List _derIntegerBody(List<int> bigEndian32) {
  var index = 0;
  while (index < bigEndian32.length && bigEndian32[index] == 0) {
    index++;
  }
  final trimmed = index == bigEndian32.length
      ? Uint8List.fromList([0])
      : Uint8List.fromList(bigEndian32.sublist(index));
  if (trimmed[0] & 0x80 != 0) {
    return Uint8List.fromList([0, ...trimmed]);
  }
  return trimmed;
}
