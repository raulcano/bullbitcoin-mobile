import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/services/cet_message_hash_service.dart';

class CetModel {
  final Uint8List txBytes;
  final List<List<int>> compressedDigitPaths;
  final Uint8List fundingScriptPubKey;
  final BigInt fundingAmountSats;
  final int fundingInputIndex;

  const CetModel({
    required this.txBytes,
    required this.compressedDigitPaths,
    required this.fundingScriptPubKey,
    required this.fundingAmountSats,
    this.fundingInputIndex = 0,
  });

  Uint8List messageHash({CetMessageHashService? hashService, int? inputIndex}) {
    final service = hashService ?? CetMessageHashService();
    return service.compute(
      this,
      inputIndex: inputIndex ?? fundingInputIndex,
    );
  }
}
