import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/domain/entity/ecdsa_adaptor_signature.dart';
import 'package:bb_mobile/core/dlc/domain/entity/ecdsa_signature.dart';
import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';
import 'package:bb_mobile/core/dlc/domain/ports/dlc_signing_repository.dart';

class DecryptAdaptorSignatureUsecase {
  final DlcSigningRepository _repository;

  DecryptAdaptorSignatureUsecase({required DlcSigningRepository repository})
    : _repository = repository;

  EcdsaSignature execute({
    required EcdsaAdaptorSignature adaptorSig,
    required Uint8List decryptionKey,
  }) {
    try {
      return _repository.decrypt(
        adaptorSig: adaptorSig,
        decryptionKey: decryptionKey,
      );
    } catch (e) {
      if (e is DlcSigningException) rethrow;
      throw DlcSigningException(e.toString());
    }
  }
}
