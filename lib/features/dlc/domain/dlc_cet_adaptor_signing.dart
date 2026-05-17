import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/ecdsa_adaptor.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_point.dart';
import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';
import 'package:bb_mobile/core/utils/uint_8_list_x.dart';

/// Signs coordinator-provided CET jobs into DLC wire adaptor signatures (162 bytes each).
List<String> signCetAdaptorJobsFromCoordinatorContext({
  required List<dynamic> cetSigningJobs,
  required Uint8List fundingPrivateKey,
}) {
  if (fundingPrivateKey.length != 32) {
    throw ArgumentError('Funding private key must be 32 bytes');
  }

  final signatures = <String>[];
  for (var i = 0; i < cetSigningJobs.length; i++) {
    final job = cetSigningJobs[i];
    if (job is! Map) {
      throw ArgumentError('cet_signing_jobs[$i] must be an object');
    }
    final map = Map<String, dynamic>.from(job);
    signatures.add(
      _signSingleCoordinatorJob(
        job: map,
        jobIndex: i,
        fundingPrivateKey: fundingPrivateKey,
      ),
    );
  }
  return signatures;
}

String _signSingleCoordinatorJob({
  required Map<String, dynamic> job,
  required int jobIndex,
  required Uint8List fundingPrivateKey,
}) {
  final messageHashHex = job['message_hash_hex'] as String?;
  final adaptorPointHex = job['adaptor_point_hex'] as String?;

  if (messageHashHex == null || messageHashHex.isEmpty) {
    throw ArgumentError(
      'cet_signing_jobs[$jobIndex] is missing message_hash_hex',
    );
  }
  if (adaptorPointHex == null || adaptorPointHex.isEmpty) {
    throw ArgumentError(
      'cet_signing_jobs[$jobIndex] is missing adaptor_point_hex',
    );
  }

  try {
    final messageHash = Uint8ListX.fromHexString(messageHashHex);
    final adaptorPoint = Secp256k1Point.fromCompressed(
      Uint8ListX.fromHexString(adaptorPointHex),
    );
    if (messageHash.length != 32) {
      throw ArgumentError(
        'cet_signing_jobs[$jobIndex] message_hash_hex must be 32 bytes',
      );
    }

    final adaptorSig = adaptorEncrypt(
      privateKey: fundingPrivateKey,
      adaptorPoint: adaptorPoint,
      messageHash: messageHash,
    );
    final wire = adaptorSig.serializeWire();
    if (wire.length != 162) {
      throw StateError(
        'Internal error: adaptor wire signature must be 162 bytes',
      );
    }
    return wire.toHexString();
  } on DlcSigningException catch (e) {
    throw ArgumentError(
      'Failed to sign cet_signing_jobs[$jobIndex]: ${e.message}',
    );
  }
}
