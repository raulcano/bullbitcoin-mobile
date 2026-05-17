import 'package:bb_mobile/core/errors/bull_exception.dart';

class DlcSigningException extends BullException {
  DlcSigningException(super.message);
}

class InvalidPrivateKeyException extends DlcSigningException {
  InvalidPrivateKeyException([String? details])
    : super(details == null ? 'Invalid private key' : 'Invalid private key: $details');
}

class InvalidPointException extends DlcSigningException {
  InvalidPointException([String? details])
    : super(details == null ? 'Invalid elliptic curve point' : 'Invalid elliptic curve point: $details');
}

class InvalidAdaptorSignatureWireException extends DlcSigningException {
  InvalidAdaptorSignatureWireException([String? details])
    : super(
        details == null
            ? 'Invalid adaptor signature wire encoding'
            : 'Invalid adaptor signature wire encoding: $details',
      );
}

class InvalidDleqProofException extends DlcSigningException {
  InvalidDleqProofException([String? details])
    : super(details == null ? 'Invalid DLEQ proof' : 'Invalid DLEQ proof: $details');
}

class DecryptionKeyMismatchException extends DlcSigningException {
  DecryptionKeyMismatchException([String? details])
    : super(
        details == null
            ? 'Decryption key does not match adaptor point'
            : 'Decryption key does not match adaptor point: $details',
      );
}

class OracleAttestationMismatchException extends DlcSigningException {
  OracleAttestationMismatchException([String? details])
    : super(
        details == null
            ? 'Oracle attestation does not match adaptor point'
            : 'Oracle attestation does not match adaptor point: $details',
      );
}
