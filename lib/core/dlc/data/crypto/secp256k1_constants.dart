import 'dart:typed_data';

/// secp256k1 curve parameters and protocol tags.
///
/// EC arithmetic uses [pointycastle] (see [Secp256k1Point]).
final BigInt secp256k1Order = BigInt.parse(
  '0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141',
);

/// Compressed generator *G*.
final Uint8List secp256k1GeneratorCompressed = Uint8List.fromList([
  0x02,
  0x79,
  0xbe,
  0x66,
  0x7e,
  0xf9,
  0xdc,
  0xbb,
  0xac,
  0x55,
  0xa0,
  0x62,
  0x95,
  0xce,
  0x87,
  0x0b,
  0x07,
  0x02,
  0x9b,
  0xfc,
  0xdb,
  0x2d,
  0xce,
  0x28,
  0xd9,
  0x59,
  0xf2,
  0x81,
  0x5b,
  0x16,
  0xf8,
  0x17,
  0x98,
]);

/// BIP62 high-*S* threshold.
final BigInt bip62HighSMax = BigInt.parse(
  '0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0',
);

/// BIP62 replacement constant for high-*S* normalization.
final BigInt bip62ReplacementS = BigInt.parse(
  '0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141',
);

const String oracleAttestationTag = 'DLC/oracle/attestation/v0';
const String bip340ChallengeTag = 'BIP0340/challenge';
const String dleqTagInput = 'DLEQ';

/// Wire layout: `R(33) || s_a(32)` — DLC encrypted adaptor prefix.
const int kWireEcdsaAdaptorBytes = 65;

/// Wire layout: `R_a(33) || b(32) || c(32)` — DLEQ proof on wire.
const int kWireDleqProofBytes = 97;

/// One CET adaptor entry on the DLC wire.
const int kWireCetAdaptorEntryBytes = 162;

/// Primitive blob: `R || R_a || s_a || proof`.
const int kEncryptedAdaptorTotalBytes = 162;
