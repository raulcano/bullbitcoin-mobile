import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/adaptor_point.dart';
import 'package:bb_mobile/core/dlc/data/crypto/ecdsa_adaptor.dart';
import 'package:bb_mobile/core/dlc/data/models/cet_model.dart';
import 'package:bb_mobile/core/dlc/data/models/contract_info_model.dart';
import 'package:bb_mobile/core/dlc/data/models/ecdsa_adaptor_signature_model.dart';
import 'package:bb_mobile/core/dlc/data/services/cet_message_hash_service.dart';
import 'package:bb_mobile/core/dlc/domain/entity/dlc_party.dart';
import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';

class AdaptorSigningService {
  final CetMessageHashService cetHashService;

  const AdaptorSigningService({required this.cetHashService});

  List<EcdsaAdaptorSignatureModel> signAllCets({
    required List<CetModel> cets,
    required ContractInfoModel contractInfo,
    required DlcParty party,
    required Uint8List fundingPrivateKey,
    List<Uint8List>? messageHashes,
  }) {
    _validatePartyAndKey(party, fundingPrivateKey);
    if (cets.isEmpty) {
      throw ArgumentError('Cannot generate adaptor signatures: no CETs found');
    }
    if (messageHashes != null && messageHashes.length != cets.length) {
      throw ArgumentError(
        'message_hashes must contain exactly one 32-byte hash per CET '
        '(${messageHashes.length} != ${cets.length})',
      );
    }

    final signatures = <EcdsaAdaptorSignatureModel>[];
    for (var i = 0; i < cets.length; i++) {
      signatures.addAll(
        signSingleCet(
          cet: cets[i],
          contractInfo: contractInfo,
          party: party,
          fundingPrivateKey: fundingPrivateKey,
          messageHash: messageHashes != null ? messageHashes[i] : null,
          componentCache: null,
        ),
      );
    }
    return signatures;
  }

  List<EcdsaAdaptorSignatureModel> signSingleCet({
    required CetModel cet,
    required ContractInfoModel contractInfo,
    required DlcParty party,
    required Uint8List fundingPrivateKey,
    Uint8List? messageHash,
    AdaptorPointComponentCache? componentCache,
  }) {
    _validatePartyAndKey(party, fundingPrivateKey);
    if (cet.compressedDigitPaths.isEmpty) {
      throw ArgumentError('CET has no compressed digit paths');
    }

    final announcement = contractInfo.oracleInfo.oracleAnnouncement;
    final cache =
        componentCache ??
        buildAdaptorPointComponentCache(
          oraclePublicKey: announcement.oraclePublicKey,
          oracleNonces: announcement.oracleNonces,
          isSigned: announcement.isSigned,
        );

    final txHash =
        messageHash ?? cet.messageHash(hashService: cetHashService);

    final signatures = <EcdsaAdaptorSignatureModel>[];
    for (final digits in cet.compressedDigitPaths) {
      final y = computeAdaptorPointFromCache(
        compressedDigits: digits,
        cache: cache,
      );
      signatures.add(
        adaptorEncrypt(
          privateKey: fundingPrivateKey,
          adaptorPoint: y,
          messageHash: txHash,
        ),
      );
    }
    return signatures;
  }

  void _validatePartyAndKey(DlcParty party, Uint8List fundingPrivateKey) {
    // party enum already validated at parse time.
    if (fundingPrivateKey.length != 32 || _isZeroKey(fundingPrivateKey)) {
      throw InvalidPrivateKeyException('must be 32 bytes different from 0');
    }
  }

  bool _isZeroKey(Uint8List key) {
    for (final b in key) {
      if (b != 0) return false;
    }
    return true;
  }
}
