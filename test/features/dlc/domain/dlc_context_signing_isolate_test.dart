import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/nonce_generator.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_context_signing_isolate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('isolate signing matches expected wire output for one CET job', () async {
    testNonceOverride = (_) => BigInt.parse('9007199254740991');

    final priv = List<int>.filled(32, 0x11);
    final result = await runDlcContextSigningOffMainThread(
      DlcContextSigningIsolateInput(
        cetSigningJobs: [
          {
            'message_hash_hex':
                '8131e6f4b45754f2c90bd06688ceeabc0c45055460729928b4eecf11026a9e2d',
            'adaptor_point_hex':
                '0324afa2587b3965c4132a135c63ff5a8cc932e1cedda1c4f9c2858c24b34039ae',
          },
        ],
        fundingPrivateKey: priv,
        contextTag: 'accept',
        seedBytes: List.filled(64, 1),
        walletDerivationPath: "m/84'/0'/0'",
        scriptTypeName: 'bip84',
        refundSighashHex: 'aa' * 32,
      ),
    );

    expect(result.cetAdaptorSignaturesHex, hasLength(1));
    expect(result.cetAdaptorSignaturesHex.first.length, 324);
    expect(result.refundSignatureHex.length, 128);

    testNonceOverride = null;
  });
}
