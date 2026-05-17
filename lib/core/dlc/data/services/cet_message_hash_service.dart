import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/models/cet_model.dart';
import 'package:crypto/crypto.dart' as crypto;

/// BIP143 SegWit v0 sighash (`SIGHASH_ALL`) for a CET funding input.
class CetMessageHashService {
  static const int sighashAll = 1;

  Uint8List compute(CetModel cet, {required int inputIndex}) {
    final tx = cet.txBytes;
    if (tx.length < 10) {
      throw ArgumentError('CET tx bytes are too short to parse');
    }

    final version = tx.sublist(0, 4);
    final inputCount = _readVarInt(tx, 4);
    var offset = inputCount.offset;

    final prevouts = <Uint8List>[];
    final sequences = <Uint8List>[];
    Uint8List? fundingOutpoint;
    Uint8List? fundingSequence;

    for (var i = 0; i < inputCount.value; i++) {
      final outpoint = tx.sublist(offset, offset + 36);
      offset += 36;
      final scriptLen = _readVarInt(tx, offset);
      offset = scriptLen.offset + scriptLen.value;
      final sequence = tx.sublist(offset, offset + 4);
      offset += 4;
      prevouts.add(outpoint);
      sequences.add(sequence);
      if (i == inputIndex) {
        fundingOutpoint = outpoint;
        fundingSequence = sequence;
      }
    }

    if (fundingOutpoint == null || fundingSequence == null) {
      throw ArgumentError('funding input index out of range');
    }

    final outputCount = _readVarInt(tx, offset);
    offset = outputCount.offset;
    final outputs = <Uint8List>[];
    for (var i = 0; i < outputCount.value; i++) {
      final value = tx.sublist(offset, offset + 8);
      offset += 8;
      final scriptLen = _readVarInt(tx, offset);
      offset = scriptLen.offset;
      final script = tx.sublist(offset, offset + scriptLen.value);
      offset += scriptLen.value;
      outputs.add(Uint8List.fromList([...value, ..._encodeVarInt(script.length), ...script]));
    }

    final locktime = tx.sublist(offset, offset + 4);
    offset += 4;

    final hashPrevouts = _hash256(Uint8List.fromList(prevouts.expand((e) => e).toList()));
    final hashSequence = _hash256(Uint8List.fromList(sequences.expand((e) => e).toList()));
    final hashOutputs = _hash256(Uint8List.fromList(outputs.expand((e) => e).toList()));

    final scriptCode = Uint8List.fromList([
      ..._encodeVarInt(cet.fundingScriptPubKey.length),
      ...cet.fundingScriptPubKey,
    ]);
    final amount = _uint64LE(cet.fundingAmountSats);

    final preimage = Uint8List.fromList([
      ...version,
      ...hashPrevouts,
      ...hashSequence,
      ...fundingOutpoint,
      ...scriptCode,
      ...amount,
      ...fundingSequence,
      ...hashOutputs,
      ...locktime,
      ..._uint32LE(sighashAll),
    ]);

    return Uint8List.fromList(_hash256(preimage));
  }

  Uint8List _hash256(Uint8List data) {
    final first = crypto.sha256.convert(data).bytes;
    return Uint8List.fromList(crypto.sha256.convert(first).bytes);
  }

  Uint8List _uint32LE(int value) {
    return Uint8List.fromList([
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ]);
  }

  Uint8List _uint64LE(BigInt value) {
    final bytes = Uint8List(8);
    var v = value;
    for (var i = 0; i < 8; i++) {
      bytes[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return bytes;
  }

  ({int value, int offset}) _readVarInt(Uint8List data, int offset) {
    final prefix = data[offset];
    if (prefix < 0xfd) {
      return (value: prefix, offset: offset + 1);
    }
    if (prefix == 0xfd) {
      final value = data[offset + 1] | (data[offset + 2] << 8);
      return (value: value, offset: offset + 3);
    }
    if (prefix == 0xfe) {
      final value = data[offset + 1] |
          (data[offset + 2] << 8) |
          (data[offset + 3] << 16) |
          (data[offset + 4] << 24);
      return (value: value, offset: offset + 5);
    }
    throw ArgumentError('8-byte varint not supported in CET parser');
  }

  Uint8List _encodeVarInt(int value) {
    if (value < 0xfd) return Uint8List.fromList([value]);
    if (value <= 0xffff) {
      return Uint8List.fromList([0xfd, value & 0xff, (value >> 8) & 0xff]);
    }
    return Uint8List.fromList([
      0xfe,
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ]);
  }
}
