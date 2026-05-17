import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/domain/entity/cet.dart';
import 'package:bb_mobile/core/dlc/domain/entity/contract_info.dart';
import 'package:bb_mobile/core/dlc/domain/entity/dlc_party.dart';
import 'package:bb_mobile/core/dlc/domain/entity/ecdsa_adaptor_signature.dart';
import 'package:bb_mobile/core/dlc/domain/entity/ecdsa_signature.dart';

abstract class DlcSigningRepository {
  Future<List<EcdsaAdaptorSignature>> signAllCets({
    required List<Cet> cets,
    required ContractInfo contractInfo,
    required DlcParty party,
    required Uint8List fundingPrivateKey,
    List<Uint8List>? messageHashes,
  });

  Future<List<EcdsaAdaptorSignature>> signSingleCet({
    required Cet cet,
    required ContractInfo contractInfo,
    required DlcParty party,
    required Uint8List fundingPrivateKey,
    Uint8List? messageHash,
  });

  bool verify({
    required Secp256k1Point signerPubKey,
    required Secp256k1Point adaptorPoint,
    required Uint8List messageHash,
    required EcdsaAdaptorSignature adaptorSig,
  });

  EcdsaSignature decrypt({
    required EcdsaAdaptorSignature adaptorSig,
    required Uint8List decryptionKey,
  });

  Uint8List recoverDecryptionKey({
    required Secp256k1Point adaptorPoint,
    required EcdsaAdaptorSignature adaptorSig,
    required EcdsaSignature decryptedSig,
  });
}
