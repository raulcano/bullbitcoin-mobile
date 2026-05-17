import 'dart:typed_data';

import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_constants.dart';
import 'package:bb_mobile/core/dlc/data/crypto/secp256k1_scalar.dart';
import 'package:bb_mobile/core/dlc/domain/errors/dlc_signing_exception.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

/// Thin wrapper over pointycastle secp256k1 curve points.
class Secp256k1Point {
  final ECPoint? _point;

  const Secp256k1Point._(this._point);

  static final Secp256k1Point infinity = Secp256k1Point._(null);

  static final ECDomainParameters _domain = ECCurve_secp256k1();

  bool get isInfinity => _point == null;

  factory Secp256k1Point.generator() => Secp256k1Point._(_domain.G);

  /// BIP340 lift-x: even-*y* compressed point from 32-byte x-only key.
  factory Secp256k1Point.fromXOnly(Uint8List xOnly) {
    if (xOnly.length != 32) {
      throw InvalidPointException('x-only key must be 32 bytes');
    }
    var x = BigInt.zero;
    for (final byte in xOnly) {
      x = (x << 8) | BigInt.from(byte);
    }
    try {
      final point = _domain.curve.decompressPoint(0, x);
      return Secp256k1Point._(point);
    } catch (e) {
      throw InvalidPointException('Invalid x-only secp256k1 coordinate: $e');
    }
  }

  factory Secp256k1Point.fromCompressed(Uint8List bytes) {
    if (bytes.length != 33) {
      throw InvalidPointException(
        'Compressed point must be 33 bytes, got ${bytes.length}',
      );
    }
    try {
      final point = _domain.curve.decodePoint(bytes);
      if (point == null || point.isInfinity) {
        throw InvalidPointException('Point is at infinity');
      }
      return Secp256k1Point._(point);
    } catch (e) {
      if (e is DlcSigningException) rethrow;
      throw InvalidPointException('Invalid compressed secp256k1 point: $e');
    }
  }

  Uint8List toCompressed() {
    if (isInfinity) {
      throw InvalidPointException('Cannot serialize point at infinity');
    }
    return Uint8List.fromList(_point!.getEncoded(true));
  }

  Uint8List xonlyBytes() {
    if (isInfinity) {
      throw InvalidPointException('Cannot take x-only of point at infinity');
    }
    return scalarToBytes32(xCoordinate);
  }

  BigInt get xCoordinate {
    if (isInfinity) {
      throw InvalidPointException('Point at infinity has no x-coordinate');
    }
    return _point!.x!.toBigInteger()!;
  }

  BigInt xModN() => xCoordinate % secp256k1Order;

  Secp256k1Point operator +(Secp256k1Point other) {
    if (isInfinity) return other;
    if (other.isInfinity) return this;
    final sum = _point! + other._point!;
    if (sum == null || sum.isInfinity) return infinity;
    return Secp256k1Point._(sum);
  }

  Secp256k1Point multiply(BigInt scalar) {
    if (isInfinity) return infinity;
    final k = scalar % secp256k1Order;
    if (k == BigInt.zero) return infinity;
    final result = _point! * k;
    if (result == null || result.isInfinity) return infinity;
    return Secp256k1Point._(result);
  }

  Secp256k1Point negate() {
    if (isInfinity) return infinity;
    return Secp256k1Point._(-_point!);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Secp256k1Point) return false;
    if (isInfinity && other.isInfinity) return true;
    if (isInfinity || other.isInfinity) return false;
    final a = toCompressed();
    final b = other.toCompressed();
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    if (isInfinity) return 0;
    return Object.hashAll(toCompressed());
  }
}
