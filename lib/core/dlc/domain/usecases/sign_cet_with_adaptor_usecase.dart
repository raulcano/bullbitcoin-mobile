import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/domain/entity/cet.dart';
import 'package:bb_mobile/core/dlc/domain/entity/contract_info.dart';
import 'package:bb_mobile/core/dlc/domain/entity/dlc_party.dart';
import 'package:bb_mobile/core/dlc/domain/entity/ecdsa_adaptor_signature.dart';
import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';
import 'package:bb_mobile/core/dlc/domain/ports/dlc_signing_repository.dart';

class SignCetWithAdaptorUsecase {
  final DlcSigningRepository _repository;

  SignCetWithAdaptorUsecase({required DlcSigningRepository repository})
    : _repository = repository;

  Future<List<EcdsaAdaptorSignature>> execute({
    required Cet cet,
    required ContractInfo contractInfo,
    required DlcParty party,
    required Uint8List fundingPrivateKey,
    Uint8List? messageHash,
  }) async {
    try {
      return _repository.signSingleCet(
        cet: cet,
        contractInfo: contractInfo,
        party: party,
        fundingPrivateKey: fundingPrivateKey,
        messageHash: messageHash,
      );
    } catch (e) {
      if (e is DlcSigningException) rethrow;
      throw DlcSigningException(e.toString());
    }
  }
}
