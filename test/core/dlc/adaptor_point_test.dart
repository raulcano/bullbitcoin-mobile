import 'package:bb_mobile/core/dlc/data/crypto/adaptor_point.dart';
import 'package:bb_mobile/core/dlc/data/models/oracle_announcement_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('computeAdaptorPoint matches known vector', () {
    final oraclePubkey = XOnlyPubKeyModel.fromHex(
      'c3b1d269468f427ec56b4d0fa14c13aa4476fb05c708f8c3f036b97f839c2741',
    );
    final oracleNonce = XOnlyPubKeyModel.fromHex(
      '509c2a8c14a6b6d546854e5b8b30ae7c759e8ba579686a85182360e0c76a67f3',
    );

    final y = computeAdaptorPoint(
      compressedDigits: [7],
      oraclePublicKey: oraclePubkey,
      oracleNonces: [oracleNonce],
      isSigned: false,
    );

    expect(
      y.toCompressed().map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      '0324afa2587b3965c4132a135c63ff5a8cc932e1cedda1c4f9c2858c24b34039ae',
    );
  });

  test('cache matches direct computation', () {
    final oraclePubkey = XOnlyPubKeyModel.fromHex(
      'c3b1d269468f427ec56b4d0fa14c13aa4476fb05c708f8c3f036b97f839c2741',
    );
    final oracleNonce = XOnlyPubKeyModel.fromHex(
      '509c2a8c14a6b6d546854e5b8b30ae7c759e8ba579686a85182360e0c76a67f3',
    );
    final cache = buildAdaptorPointComponentCache(
      oraclePublicKey: oraclePubkey,
      oracleNonces: [oracleNonce],
      isSigned: false,
    );
    final fromCache = computeAdaptorPointFromCache(
      compressedDigits: [7],
      cache: cache,
    );
    final direct = computeAdaptorPoint(
      compressedDigits: [7],
      oraclePublicKey: oraclePubkey,
      oracleNonces: [oracleNonce],
      isSigned: false,
    );
    expect(fromCache, direct);
  });
}
