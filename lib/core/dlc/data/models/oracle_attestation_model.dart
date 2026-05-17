import 'package:bb_mobile/core/dlc/data/models/oracle_announcement_model.dart';
import 'package:bb_mobile/core/dlc/data/models/schnorr_signature_model.dart';

class OracleAttestationModel {
  final XOnlyPubKeyModel oraclePublicKey;
  final List<SchnorrSignatureModel> signatures;
  final List<String> outcomes;

  const OracleAttestationModel({
    required this.oraclePublicKey,
    required this.signatures,
    required this.outcomes,
  });
}
