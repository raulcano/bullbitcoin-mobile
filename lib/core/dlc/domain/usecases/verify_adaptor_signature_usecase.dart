import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/domain/entity/ecdsa_adaptor_signature.dart';
import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';
import 'package:bb_mobile/core/dlc/domain/ports/dlc_signing_repository.dart';

class VerifyAdaptorSignatureUsecase {
  final DlcSigningRepository _repository;

  VerifyAdaptorSignatureUsecase({required DlcSigningRepository repository})
    : _repository = repository;

  bool execute({
    required Secp256k1Point signerPubKey,
    required Secp256k1Point adaptorPoint,
    required Uint8List messageHash,
    required EcdsaAdaptorSignature adaptorSig,
  }) {
    try {
      return _repository.verify(
        signerPubKey: signerPubKey,
        adaptorPoint: adaptorPoint,
        messageHash: messageHash,
        adaptorSig: adaptorSig,
      );
    } catch (e) {
      if (e is DlcSigningException) rethrow;
      throw DlcSigningException(e.toString());
    }
  }
}
