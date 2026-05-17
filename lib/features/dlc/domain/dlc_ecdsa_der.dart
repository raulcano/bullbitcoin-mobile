import 'dart:typed_data';

import 'package:bb_mobile/core/utils/uint_8_list_x.dart';

/// DER-encodes a 64-byte compact secp256k1 signature (BIP340-style r||s).
String compactSecp256k1SignatureToDerHex(
  Uint8List compactSignature, {
  bool includeHashType = false,
}) {
  if (compactSignature.length != 64) {
    throw ArgumentError(
      'Compact signature must be 64 bytes, got ${compactSignature.length}',
    );
  }

  final r = _trimLeadingZeros(compactSignature.sublist(0, 32));
  final s = _trimLeadingZeros(compactSignature.sublist(32, 64));
  final rDer = (r.isNotEmpty && (r.first & 0x80) != 0)
      ? Uint8List.fromList([0, ...r])
      : Uint8List.fromList(r);
  final sDer = (s.isNotEmpty && (s.first & 0x80) != 0)
      ? Uint8List.fromList([0, ...s])
      : Uint8List.fromList(s);

  final sequenceLen = 2 + rDer.length + 2 + sDer.length;
  final der = Uint8List.fromList([
    0x30,
    sequenceLen,
    0x02,
    rDer.length,
    ...rDer,
    0x02,
    sDer.length,
    ...sDer,
  ]);
  final withHashType = includeHashType
      ? Uint8List.fromList([...der, 0x01])
      : der;
  return withHashType.toHexString();
}

List<int> _trimLeadingZeros(List<int> bytes) {
  var index = 0;
  while (index < bytes.length - 1 && bytes[index] == 0) {
    index++;
  }
  return bytes.sublist(index);
}
