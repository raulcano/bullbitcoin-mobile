import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/models/oracle_announcement_model.dart';
import 'package:bb_mobile/core/dlc/data/models/schnorr_signature_model.dart';

class SchnorrSignature {
  final SchnorrSignatureModel _model;

  const SchnorrSignature(this._model);

  SchnorrSignatureModel get model => _model;

  bool verify(XOnlyPubKeyModel publicKey, Uint8List message) {
    return _model.verify(publicKey, message);
  }
}
