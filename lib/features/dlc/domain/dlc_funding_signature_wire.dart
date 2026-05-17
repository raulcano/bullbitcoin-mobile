import 'dart:typed_data';

import 'package:bb_mobile/core/utils/uint_8_list_x.dart';
import 'package:convert/convert.dart';

/// DLC wire encoding for [FundingSignature] / witness stacks (coordinator-compatible).
///
/// Each funding input is a P2WPKH witness stack: `[DER sig + SIGHASH_ALL, compressed pubkey]`.
/// Accept/sign payloads must send **one** serialized container in `funding_signatures_hex`.

const int sighashAll = 0x01;

Uint8List encodeBigSize(int value) {
  if (value < 0) {
    throw ArgumentError('BigSize value must be non-negative');
  }
  if (value <= 0xfc) {
    return Uint8List.fromList([value]);
  }
  if (value <= 0xffff) {
    final bytes = ByteData(2)..setUint16(0, value, Endian.big);
    return Uint8List.fromList([0xfd, ...bytes.buffer.asUint8List()]);
  }
  if (value <= 0xffffffff) {
    final bytes = ByteData(4)..setUint32(0, value, Endian.big);
    return Uint8List.fromList([0xfe, ...bytes.buffer.asUint8List()]);
  }
  final bytes = ByteData(8)..setUint64(0, value, Endian.big);
  return Uint8List.fromList([0xff, ...bytes.buffer.asUint8List()]);
}

Uint8List encodeWitnessElement(Uint8List witness) {
  if (witness.isEmpty) {
    throw ArgumentError('WitnessElement must not be empty');
  }
  return Uint8List.fromList([...encodeBigSize(witness.length), ...witness]);
}

Uint8List encodeWitnessStack(List<Uint8List> witnessElements) {
  if (witnessElements.isEmpty) {
    throw ArgumentError('WitnessStack must not be empty');
  }
  return Uint8List.fromList([
    ...encodeBigSize(witnessElements.length),
    for (final element in witnessElements) ...encodeWitnessElement(element),
  ]);
}

/// Serializes a single [FundingSignature] (all funding-input witness stacks).
String serializeFundingSignatureHex({
  required List<Uint8List> witnessStacks,
}) {
  if (witnessStacks.isEmpty) {
    throw ArgumentError('FundingSignature requires at least one witness stack');
  }
  final payload = Uint8List.fromList([
    ...encodeBigSize(witnessStacks.length),
    for (final stack in witnessStacks) ...stack,
  ]);
  return payload.toHexString();
}

/// Builds one P2WPKH witness stack from a funding-input sighash and signing key.
Uint8List encodeP2wpkhFundingWitnessStack({
  required String derSignatureHex,
  required Uint8List compressedPubkey33,
}) {
  if (compressedPubkey33.length != 33) {
    throw ArgumentError('Funding pubkey must be 33-byte compressed secp256k1');
  }
  final derWithHashType = _appendSighashAll(_derBytesFromHex(derSignatureHex));
  return encodeWitnessStack([derWithHashType, compressedPubkey33]);
}

Uint8List _derBytesFromHex(String derHex) {
  return Uint8List.fromList(hex.decode(derHex));
}

Uint8List _appendSighashAll(Uint8List der) {
  if (der.isNotEmpty && der.last == sighashAll) {
    return der;
  }
  return Uint8List.fromList([...der, sighashAll]);
}
