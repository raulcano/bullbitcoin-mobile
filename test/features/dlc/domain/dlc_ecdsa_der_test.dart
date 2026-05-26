import 'dart:typed_data';

import 'package:bb_mobile/features/dlc/domain/dlc_ecdsa_der.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('compactSecp256k1SignatureToDerHex', () {
    test('DER + sighash parses as valid ASN.1 length', () {
      final compact = Uint8List(64);
      compact[0] = 0x00;
      compact[1] = 0x80;
      compact[32] = 0x40;
      compact[63] = 0x7f;

      final hex = compactSecp256k1SignatureToDerHex(
        compact,
        includeHashType: true,
      );
      final bytes = Uint8List.fromList(
        List.generate(hex.length ~/ 2, (i) {
          return int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
        }),
      );

      expect(bytes.first, 0x30);
      expect(bytes.last, 0x01);
      final seqLen = bytes[1];
      final derBody = bytes.sublist(2, 2 + seqLen);
      expect(derBody.length, seqLen);
      expect(bytes.length, 2 + seqLen + 1);
    });

    test('UTXO proofs use DER without sighash suffix', () {
      final compact = Uint8List(64);
      compact[0] = 0x10;
      compact[32] = 0x20;
      final hex = compactSecp256k1SignatureToDerHex(compact);
      final bytes = Uint8List.fromList(
        List.generate(hex.length ~/ 2, (i) {
          return int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
        }),
      );
      expect(bytes.length, greaterThan(2));
      expect(bytes.first, 0x30);
      // Registration adds an extra 0x01 after DER; bare DER must not be padded.
      expect(bytes.length, bytes[1] + 2);
    });
  });
}
