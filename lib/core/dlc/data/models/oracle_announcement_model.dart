import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';

/// 32-byte BIP340 x-only public key.
class XOnlyPubKeyModel {
  final Uint8List bytes;

  XOnlyPubKeyModel(this.bytes) {
    if (bytes.length != 32) {
      throw InvalidPointException('x-only pubkey must be 32 bytes');
    }
  }

  factory XOnlyPubKeyModel.fromHex(String hex) {
    final cleaned = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (cleaned.length != 64) {
      throw InvalidPointException('x-only pubkey hex must be 64 characters');
    }
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return XOnlyPubKeyModel(out);
  }

  /// Lift x-only key to compressed secp256k1 point (even *y*, BIP340).
  Uint8List toCompressedPoint() {
    return Secp256k1Point.fromXOnly(bytes).toCompressed();
  }

  String toHex() => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class EventDescriptorModel {
  final bool isSigned;
  final int base;
  final int nbDigits;
  final String unit;
  final int precision;

  const EventDescriptorModel({
    required this.isSigned,
    required this.base,
    required this.nbDigits,
    required this.unit,
    required this.precision,
  });
}

class OracleEventModel {
  final int eventMaturityEpoch;
  final EventDescriptorModel eventDescriptor;
  final List<XOnlyPubKeyModel> oracleNonces;

  const OracleEventModel({
    required this.eventMaturityEpoch,
    required this.eventDescriptor,
    required this.oracleNonces,
  });
}

class OracleAnnouncementModel {
  final XOnlyPubKeyModel oraclePublicKey;
  final OracleEventModel oracleEvent;
  final String eventId;

  const OracleAnnouncementModel({
    required this.oraclePublicKey,
    required this.oracleEvent,
    required this.eventId,
  });

  bool get isSigned => oracleEvent.eventDescriptor.isSigned;

  List<XOnlyPubKeyModel> get oracleNonces => oracleEvent.oracleNonces;
}

class OracleInfoModel {
  final OracleAnnouncementModel oracleAnnouncement;

  const OracleInfoModel({required this.oracleAnnouncement});
}
