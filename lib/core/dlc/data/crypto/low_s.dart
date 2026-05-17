import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_constants.dart';

bool isHighS(BigInt s) => s > bip62HighSMax;

BigInt normalizeToLowS(BigInt s, {bool force = false}) {
  final normalized = s % secp256k1Order;
  if (force || isHighS(normalized)) {
    return (bip62ReplacementS - normalized) % secp256k1Order;
  }
  return normalized;
}
