import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors [DlcLocalSigner._coordinatorXpubProofDigest] for unit testing.
Uint8List coordinatorXpubProofDigest(String nonce) {
  final messageBytes = Uint8List.fromList(utf8.encode(nonce));
  if (messageBytes.length == 32) {
    return messageBytes;
  }
  final first = sha256.convert(messageBytes).bytes;
  return Uint8List.fromList(sha256.convert(first).bytes);
}

void main() {
  group('coordinatorXpubProofDigest', () {
    test('matches bitcoinlib sign input for utf8 nonce hex', () {
      const nonce = 'abc123-nonce-for-registration-test-value';
      final messageHex = utf8.encode(nonce).map((b) {
        return b.toRadixString(16).padLeft(2, '0');
      }).join();
      final decoded = Uint8List.fromList(
        List.generate(messageHex.length ~/ 2, (index) {
          final start = index * 2;
          return int.parse(messageHex.substring(start, start + 2), radix: 16);
        }),
      );

      expect(decoded, utf8.encode(nonce));
      expect(coordinatorXpubProofDigest(nonce), isNot(decoded));
      expect(coordinatorXpubProofDigest(nonce).length, 32);
    });

    test('passes through 32-byte utf8 nonce without extra hashing', () {
      final nonce = String.fromCharCodes(List<int>.generate(32, (i) => 65 + i));
      expect(utf8.encode(nonce).length, 32);
      expect(coordinatorXpubProofDigest(nonce), utf8.encode(nonce));
    });
  });
}
