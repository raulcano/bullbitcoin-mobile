import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/models/ecdsa_adaptor_signature_model.dart';

class EcdsaAdaptorSignature {
  final EcdsaAdaptorSignatureModel _model;

  const EcdsaAdaptorSignature(this._model);

  EcdsaAdaptorSignatureModel get model => _model;

  Uint8List serializeWire() => _model.serializeWire();

  Uint8List toEncryptedAdaptorBytes() => _model.toEncryptedAdaptorBytes();

  static EcdsaAdaptorSignature deserializeWire(Uint8List data) {
    return EcdsaAdaptorSignature(EcdsaAdaptorSignatureModel.deserializeWire(data));
  }
}
