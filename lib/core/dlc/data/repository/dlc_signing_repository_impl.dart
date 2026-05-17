import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/ecdsa_adaptor.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/data/services/adaptor_signing_service.dart';
import 'package:bb_mobile/core/dlc/domain/entity/cet.dart';
import 'package:bb_mobile/core/dlc/domain/entity/contract_info.dart';
import 'package:bb_mobile/core/dlc/domain/entity/dlc_party.dart';
import 'package:bb_mobile/core/dlc/domain/entity/ecdsa_adaptor_signature.dart';
import 'package:bb_mobile/core/dlc/domain/entity/ecdsa_signature.dart';
import 'package:bb_mobile/core/dlc/domain/ports/dlc_signing_repository.dart';

class DlcSigningRepositoryImpl implements DlcSigningRepository {
  final AdaptorSigningService signingService;

  DlcSigningRepositoryImpl({required this.signingService});

  @override
  Future<List<EcdsaAdaptorSignature>> signAllCets({
    required List<Cet> cets,
    required ContractInfo contractInfo,
    required DlcParty party,
    required Uint8List fundingPrivateKey,
    List<Uint8List>? messageHashes,
  }) async {
    final models = signingService.signAllCets(
      cets: cets.map((c) => c.model).toList(),
      contractInfo: contractInfo.model,
      party: party,
      fundingPrivateKey: fundingPrivateKey,
      messageHashes: messageHashes,
    );
    return models.map(EcdsaAdaptorSignature.new).toList();
  }

  @override
  Future<List<EcdsaAdaptorSignature>> signSingleCet({
    required Cet cet,
    required ContractInfo contractInfo,
    required DlcParty party,
    required Uint8List fundingPrivateKey,
    Uint8List? messageHash,
  }) async {
    final models = signingService.signSingleCet(
      cet: cet.model,
      contractInfo: contractInfo.model,
      party: party,
      fundingPrivateKey: fundingPrivateKey,
      messageHash: messageHash,
    );
    return models.map(EcdsaAdaptorSignature.new).toList();
  }

  @override
  bool verify({
    required Secp256k1Point signerPubKey,
    required Secp256k1Point adaptorPoint,
    required Uint8List messageHash,
    required EcdsaAdaptorSignature adaptorSig,
  }) {
    return adaptorVerify(
      signerPublicKey: signerPubKey,
      adaptorPoint: adaptorPoint,
      messageHash: messageHash,
      encryptedAdaptorBytes: adaptorSig.model.toEncryptedAdaptorBytes(),
    );
  }

  @override
  EcdsaSignature decrypt({
    required EcdsaAdaptorSignature adaptorSig,
    required Uint8List decryptionKey,
  }) {
    return EcdsaSignature(
      adaptorDecrypt(
        encryptedAdaptorBytes: adaptorSig.model.toEncryptedAdaptorBytes(),
        decryptionKey: decryptionKey,
      ),
    );
  }

  @override
  Uint8List recoverDecryptionKey({
    required Secp256k1Point adaptorPoint,
    required EcdsaAdaptorSignature adaptorSig,
    required EcdsaSignature decryptedSig,
  }) {
    return adaptorRecoverDecryptionKey(
      adaptorPoint: adaptorPoint,
      encryptedAdaptorBytes: adaptorSig.model.toEncryptedAdaptorBytes(),
      signature: decryptedSig.model,
    );
  }
}
