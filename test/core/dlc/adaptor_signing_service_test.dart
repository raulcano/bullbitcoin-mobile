import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/adaptor_point.dart';
import 'package:bb_mobile/core/dlc/data/crypto/ecdsa_adaptor.dart';
import 'package:bb_mobile/core/dlc/data/crypto/nonce_generator.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/data/models/cet_model.dart';
import 'package:bb_mobile/core/dlc/data/models/contract_info_model.dart';
import 'package:bb_mobile/core/dlc/data/models/oracle_announcement_model.dart';
import 'package:bb_mobile/core/dlc/data/services/adaptor_signing_service.dart';
import 'package:bb_mobile/core/dlc/data/services/cet_message_hash_service.dart';
import 'package:bb_mobile/core/dlc/domain/entity/dlc_party.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String hex) => Uint8List.fromList(
  List.generate(hex.length ~/ 2, (i) {
    return int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }),
);

void main() {
  test('signSingleCet with message hash override produces verifiable adaptor sig', () {
    final announcement = OracleAnnouncementModel(
      oraclePublicKey: XOnlyPubKeyModel.fromHex(
        'c3b1d269468f427ec56b4d0fa14c13aa4476fb05c708f8c3f036b97f839c2741',
      ),
      oracleEvent: OracleEventModel(
        eventMaturityEpoch: 1,
        eventDescriptor: const EventDescriptorModel(
          isSigned: false,
          base: 0,
          nbDigits: 1,
          unit: 'bits',
          precision: 0,
        ),
        oracleNonces: [
          XOnlyPubKeyModel.fromHex(
            '509c2a8c14a6b6d546854e5b8b30ae7c759e8ba579686a85182360e0c76a67f3',
          ),
        ],
      ),
      eventId: 'test',
    );
    final contract = ContractInfoModel(
      oracleInfo: OracleInfoModel(oracleAnnouncement: announcement),
    );
    final cet = CetModel(
      txBytes: Uint8List.fromList([0x02, 0x00, 0x00, 0x00]),
      compressedDigitPaths: [
        [7],
      ],
      fundingScriptPubKey: Uint8List(0),
      fundingAmountSats: BigInt.zero,
    );

    final priv = _hex('11' * 32);
    var scalar = BigInt.zero;
    for (final b in priv) {
      scalar = (scalar << 8) | BigInt.from(b);
    }
    final pub = Secp256k1Point.generator().multiply(scalar).toCompressed();
    final messageHash = _hex(
      '8131e6f4b45754f2c90bd06688ceeabc0c45055460729928b4eecf11026a9e2d',
    );

    testNonceOverride = (_) => BigInt.parse('9007199254740991');

    final service = AdaptorSigningService(cetHashService: CetMessageHashService());
    final sigs = service.signSingleCet(
      cet: cet,
      contractInfo: contract,
      party: DlcParty.offerer,
      fundingPrivateKey: priv,
      messageHash: messageHash,
    );

    expect(sigs, hasLength(1));
    final sig = sigs.first;
    final y = computeAdaptorPoint(
      compressedDigits: [7],
      oraclePublicKey: announcement.oraclePublicKey,
      oracleNonces: announcement.oracleNonces,
      isSigned: false,
    );

    expect(
      adaptorVerify(
        signerPublicKey: Secp256k1Point.fromCompressed(pub),
        adaptorPoint: y,
        messageHash: messageHash,
        encryptedAdaptorBytes: sig.toEncryptedAdaptorBytes(),
      ),
      isTrue,
    );

    testNonceOverride = null;
  });
}
