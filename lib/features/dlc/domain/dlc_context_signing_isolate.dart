import 'dart:convert';

import 'package:bb_mobile/core/utils/uint_8_list_x.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_cet_adaptor_signing.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_compact_ecdsa.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_ecdsa_der.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_funding_signature_wire.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

/// Serializable payload for [compute] — only sendable types.
class DlcContextSigningIsolateInput {
  final List<Map<String, dynamic>> cetSigningJobs;
  final List<int> fundingPrivateKey;
  final String contextTag;
  final String? refundSighashHex;
  final List<String> fundingInputSighashesHex;
  final List<DlcFundingInputSigningMaterial> fundingInputKeys;

  const DlcContextSigningIsolateInput({
    required this.cetSigningJobs,
    required this.fundingPrivateKey,
    required this.contextTag,
    this.refundSighashHex,
    this.fundingInputSighashesHex = const [],
    this.fundingInputKeys = const [],
  });

  Map<String, dynamic> toJson() => {
    'cet_signing_jobs': cetSigningJobs,
    'funding_private_key': fundingPrivateKey,
    'context_tag': contextTag,
    'refund_sighash_hex': refundSighashHex,
    'funding_input_sighashes_hex': fundingInputSighashesHex,
    'funding_input_keys': fundingInputKeys.map((k) => k.toJson()).toList(),
  };

  factory DlcContextSigningIsolateInput.fromJson(Map<String, dynamic> json) {
    return DlcContextSigningIsolateInput(
      cetSigningJobs: (json['cet_signing_jobs'] as List<dynamic>)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      fundingPrivateKey: (json['funding_private_key'] as List<dynamic>)
          .cast<int>(),
      contextTag: json['context_tag'] as String,
      refundSighashHex: json['refund_sighash_hex'] as String?,
      fundingInputSighashesHex:
          (json['funding_input_sighashes_hex'] as List<dynamic>? ?? const [])
              .cast<String>(),
      fundingInputKeys:
          (json['funding_input_keys'] as List<dynamic>? ?? const [])
              .map(
                (e) => DlcFundingInputSigningMaterial.fromJson(
                  Map<String, dynamic>.from(e as Map),
                ),
              )
              .toList(),
    );
  }
}

class DlcFundingInputSigningMaterial {
  final List<int> privateKey;
  final List<int> publicKey;

  const DlcFundingInputSigningMaterial({
    required this.privateKey,
    required this.publicKey,
  });

  Map<String, dynamic> toJson() => {
    'private_key': privateKey,
    'public_key': publicKey,
  };

  factory DlcFundingInputSigningMaterial.fromJson(Map<String, dynamic> json) {
    return DlcFundingInputSigningMaterial(
      privateKey: (json['private_key'] as List<dynamic>).cast<int>(),
      publicKey: (json['public_key'] as List<dynamic>).cast<int>(),
    );
  }
}

class DlcContextSigningIsolateOutput {
  final List<String> cetAdaptorSignaturesHex;
  final String refundSignatureHex;
  final List<String> fundingSignaturesHex;

  const DlcContextSigningIsolateOutput({
    required this.cetAdaptorSignaturesHex,
    required this.refundSignatureHex,
    required this.fundingSignaturesHex,
  });

  Map<String, dynamic> toJson() => {
    'cet_adaptor_signatures_hex': cetAdaptorSignaturesHex,
    'refund_signature_hex': refundSignatureHex,
    'funding_signatures_hex': fundingSignaturesHex,
  };

  factory DlcContextSigningIsolateOutput.fromJson(Map<String, dynamic> json) {
    return DlcContextSigningIsolateOutput(
      cetAdaptorSignaturesHex:
          (json['cet_adaptor_signatures_hex'] as List<dynamic>).cast<String>(),
      refundSignatureHex: json['refund_signature_hex'] as String,
      fundingSignaturesHex:
          (json['funding_signatures_hex'] as List<dynamic>).cast<String>(),
    );
  }
}

/// Runs DLC adaptor + refund + funding signing off the UI isolate.
Future<DlcContextSigningIsolateOutput> runDlcContextSigningOffMainThread(
  DlcContextSigningIsolateInput input,
) {
  return compute(_signDlcContextIsolate, input.toJson()).then(
    (json) => DlcContextSigningIsolateOutput.fromJson(json),
  );
}

Map<String, dynamic> _signDlcContextIsolate(Map<String, dynamic> raw) {
  final input = DlcContextSigningIsolateInput.fromJson(raw);
  final fundingPrivateKey = Uint8List.fromList(input.fundingPrivateKey);

  final cetSigs = signCetAdaptorJobsFromCoordinatorContext(
    cetSigningJobs: input.cetSigningJobs,
    fundingPrivateKey: fundingPrivateKey,
  );

  final refundHash = input.refundSighashHex == null ||
          input.refundSighashHex!.isEmpty
      ? crypto.sha256.convert(utf8.encode('${input.contextTag}:refund')).bytes
      : hex.decode(input.refundSighashHex!);
  final refundCompact = signCompactSecp256k1(
    privateKey32: fundingPrivateKey,
    digest32: Uint8List.fromList(refundHash),
  );
  final refundSignatureHex = refundCompact.toHexString();

  final witnessStacks = <Uint8List>[];
  for (var i = 0; i < input.fundingInputSighashesHex.length; i++) {
    final sighash = Uint8List.fromList(hex.decode(input.fundingInputSighashesHex[i]));
    final material = input.fundingInputKeys[i];
    final compact = signCompactSecp256k1(
      privateKey32: Uint8List.fromList(material.privateKey),
      digest32: sighash,
    );
    witnessStacks.add(
      encodeP2wpkhFundingWitnessStack(
        derSignatureHex: compactSecp256k1SignatureToDerHex(compact),
        compressedPubkey33: Uint8List.fromList(material.publicKey),
      ),
    );
  }

  final fundingSignaturesHex = witnessStacks.isEmpty
      ? <String>[]
      : [serializeFundingSignatureHex(witnessStacks: witnessStacks)];

  return DlcContextSigningIsolateOutput(
    cetAdaptorSignaturesHex: cetSigs,
    refundSignatureHex: refundSignatureHex,
    fundingSignaturesHex: fundingSignaturesHex,
  ).toJson();
}
