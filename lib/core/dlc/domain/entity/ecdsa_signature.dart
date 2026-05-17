import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/models/ecdsa_signature_model.dart';

class EcdsaSignature {
  final EcdsaSignatureModel _model;

  const EcdsaSignature(this._model);

  EcdsaSignatureModel get model => _model;

  Uint8List serialize() => _model.serialize();

  static EcdsaSignature deserialize(Uint8List data) {
    return EcdsaSignature(EcdsaSignatureModel.deserialize(data));
  }
}
