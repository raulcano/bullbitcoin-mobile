import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/domain/entity/ecdsa_adaptor_signature.dart';

class AdaptorSigningResult {
  final List<EcdsaAdaptorSignature> signatures;
  final List<Secp256k1Point> adaptorPoints;

  const AdaptorSigningResult({
    required this.signatures,
    required this.adaptorPoints,
  });
}
