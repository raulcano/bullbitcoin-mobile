import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/domain/entity/ecdsa_adaptor_signature.dart';
import 'package:bb_mobile/core/dlc/domain/entity/ecdsa_signature.dart';
import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';
import 'package:bb_mobile/core/dlc/domain/ports/dlc_signing_repository.dart';

class RecoverDecryptionKeyUsecase {
  final DlcSigningRepository _repository;

  RecoverDecryptionKeyUsecase({required DlcSigningRepository repository})
    : _repository = repository;

  Uint8List execute({
    required Secp256k1Point adaptorPoint,
    required EcdsaAdaptorSignature adaptorSig,
    required EcdsaSignature decryptedSig,
  }) {
    try {
      return _repository.recoverDecryptionKey(
        adaptorPoint: adaptorPoint,
        adaptorSig: adaptorSig,
        decryptedSig: decryptedSig,
      );
    } catch (e) {
      if (e is DlcSigningException) rethrow;
      throw DlcSigningException(e.toString());
    }
  }
}
