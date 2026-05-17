import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/models/cet_model.dart';

class Cet {
  final CetModel _model;

  const Cet(this._model);

  CetModel get model => _model;

  Uint8List messageHash({int? inputIndex}) => _model.messageHash(inputIndex: inputIndex);
}
