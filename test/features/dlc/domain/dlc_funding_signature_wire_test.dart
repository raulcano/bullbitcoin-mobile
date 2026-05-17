import 'dart:typed_data';

import 'package:bb_mobile/core/utils/uint_8_list_x.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_funding_signature_wire.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('serializeFundingSignatureHex', () {
    test('wraps multiple witness stacks in one container', () {
      final stackA = encodeWitnessStack([
        Uint8List.fromList([0x30, 0x01, 0x01, sighashAll]),
        Uint8List.fromList([0x02, 0x03, 0x04]),
      ]);
      final stackB = encodeWitnessStack([
        Uint8List.fromList([0x31, 0x02, 0x02, sighashAll]),
        Uint8List.fromList([0x05, 0x06, 0x07]),
      ]);

      final hex = serializeFundingSignatureHex(
        witnessStacks: [stackA, stackB],
      );

      expect(hex.startsWith('02'), isTrue);
      expect(hex.contains(stackA.toHexString()), isTrue);
    });

    test('single-stack container matches coordinator bigsize prefix', () {
      final stack = encodeWitnessStack([
        Uint8List.fromList(List<int>.generate(70, (i) => i % 256) + [sighashAll]),
        Uint8List.fromList(List<int>.generate(33, (i) => 0x20 + i)),
      ]);
      final hex = serializeFundingSignatureHex(witnessStacks: [stack]);

      expect(hex.startsWith('01'), isTrue);
    });
  });
}
