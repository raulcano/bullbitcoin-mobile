// Models for POST /orders/option-payout-simulation.

class DlcOptionPayoutSimulationRequest {
  const DlcOptionPayoutSimulationRequest({
    required this.side,
    required this.role,
    required this.optionRight,
    required this.numContracts,
    required this.strike,
    required this.premiumPerContractSats,
    required this.outcomePrice,
    required this.premiumPaidUpfront,
    this.networkFeeSats = 0,
    this.numDigits = 8,
  });

  /// Wallet option side: `buy` or `sell`.
  final String side;

  /// Wallet order role: `maker` or `taker`.
  final String role;

  final String optionRight;
  final double numContracts;
  final int strike;
  final int premiumPerContractSats;
  final int outcomePrice;
  final bool premiumPaidUpfront;
  final int networkFeeSats;
  final int numDigits;

  /// Does not include `wallet_fee_sats`; the coordinator derives it from the
  /// wallet partner configuration and [role].
  Map<String, dynamic> toJson() => {
    'side': side,
    'role': role,
    'option_right': optionRight,
    'num_contracts': numContracts,
    'strike': strike,
    'premium_per_contract_sats': premiumPerContractSats,
    'outcome_price': outcomePrice,
    'premium_paid_upfront': premiumPaidUpfront,
    'network_fee_sats': networkFeeSats,
    'num_digits': numDigits,
  };
}

class DlcPayoutInterval {
  const DlcPayoutInterval({
    required this.index,
    required this.start,
    required this.end,
    required this.walletPayout,
    required this.counterpartyPayout,
    required this.compressedDigitCount,
  });

  final int index;
  final int start;
  final int end;
  final int walletPayout;
  final int counterpartyPayout;
  final int compressedDigitCount;

  factory DlcPayoutInterval.fromJson(Map<String, dynamic> json) {
    return DlcPayoutInterval(
      index: _readInt(json['index']),
      start: _readInt(json['start']),
      end: _readInt(json['end']),
      walletPayout: _readInt(json['wallet_payout']),
      counterpartyPayout: _readInt(json['counterparty_payout']),
      compressedDigitCount: _readInt(json['compressed_digit_count']),
    );
  }
}

class DlcCanonicalPoint {
  const DlcCanonicalPoint({
    required this.x,
    required this.walletPayout,
    required this.counterpartyPayout,
  });

  final int x;
  final int walletPayout;
  final int counterpartyPayout;

  factory DlcCanonicalPoint.fromJson(Map<String, dynamic> json) {
    return DlcCanonicalPoint(
      x: _readInt(json['x']),
      walletPayout: _readInt(json['wallet_payout']),
      counterpartyPayout: _readInt(json['counterparty_payout']),
    );
  }
}

/// Oracle outcome interval containing [outcomePrice], if returned by API.
class DlcOutcomeIntervalBand {
  const DlcOutcomeIntervalBand({required this.start, required this.end});

  final int start;
  final int end;

  factory DlcOutcomeIntervalBand.fromJson(Map<String, dynamic> json) {
    return DlcOutcomeIntervalBand(
      start: _readInt(json['start']),
      end: _readInt(json['end']),
    );
  }
}

/// Parsed wallet-perspective simulation payload.
///
/// The coordinator may include extra keys (for example `wallet_fee_partner_id`)
/// that are intentionally ignored — they are not shown in the simulate outcome UI.
class DlcOptionPayoutSimulationResult {
  const DlcOptionPayoutSimulationResult({
    required this.roundedPnlSats,
    required this.canonicalPnlSats,
    required this.walletPostedCollateralSats,
    required this.premiumPaidUpfrontSats,
    required this.premiumReceivedUpfrontSats,
    required this.premiumEmbeddedInDlcSats,
    required this.walletRoundedSettlementPayoutSats,
    required this.walletCanonicalPayoutSats,
    required this.networkFeeSats,
    required this.walletFeeSats,
    required this.totalFeeSats,
    required this.roundingDeltaSats,
    required this.intervals,
    required this.canonicalPoints,
    required this.outcomeInterval,
  });

  final int roundedPnlSats;
  final int canonicalPnlSats;
  final int walletPostedCollateralSats;
  final int premiumPaidUpfrontSats;
  final int premiumReceivedUpfrontSats;
  final int premiumEmbeddedInDlcSats;
  final int walletRoundedSettlementPayoutSats;
  final int walletCanonicalPayoutSats;
  final int networkFeeSats;
  final int walletFeeSats;
  final int totalFeeSats;
  final int roundingDeltaSats;

  final List<DlcPayoutInterval> intervals;
  final List<DlcCanonicalPoint> canonicalPoints;
  final DlcOutcomeIntervalBand? outcomeInterval;

  factory DlcOptionPayoutSimulationResult.fromJson(Map<String, dynamic> json) {
    final intervalsRaw = json['intervals'];
    final intervals = <DlcPayoutInterval>[];
    if (intervalsRaw is List<dynamic>) {
      for (final item in intervalsRaw) {
        if (item is Map<String, dynamic>) {
          intervals.add(DlcPayoutInterval.fromJson(item));
        } else if (item is Map) {
          intervals.add(
            DlcPayoutInterval.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }

    final canonRaw = json['canonical_points'];
    final canonicalPoints = <DlcCanonicalPoint>[];
    if (canonRaw is List<dynamic>) {
      for (final item in canonRaw) {
        if (item is Map<String, dynamic>) {
          canonicalPoints.add(DlcCanonicalPoint.fromJson(item));
        } else if (item is Map) {
          canonicalPoints.add(
            DlcCanonicalPoint.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }

    return DlcOptionPayoutSimulationResult(
      roundedPnlSats: _readInt(json['rounded_pnl_sats']),
      canonicalPnlSats: _readInt(json['canonical_pnl_sats']),
      walletPostedCollateralSats: _readInt(json['wallet_posted_collateral_sats']),
      premiumPaidUpfrontSats: _readInt(json['premium_paid_upfront_sats']),
      premiumReceivedUpfrontSats: _readInt(
        json['premium_received_upfront_sats'],
      ),
      premiumEmbeddedInDlcSats: _readInt(json['premium_embedded_in_dlc_sats']),
      walletRoundedSettlementPayoutSats: _readInt(
        json['wallet_rounded_settlement_payout_sats'],
      ),
      walletCanonicalPayoutSats: _readInt(json['wallet_canonical_payout_sats']),
      networkFeeSats: _readInt(json['network_fee_sats']),
      walletFeeSats: _readInt(json['wallet_fee_sats']),
      totalFeeSats: _readInt(json['total_fee_sats']),
      roundingDeltaSats: _readInt(json['rounding_delta_sats']),
      intervals: intervals,
      canonicalPoints: canonicalPoints,
      outcomeInterval: _parseOutcomeInterval(json['outcome_interval']),
    );
  }
}

DlcOutcomeIntervalBand? _parseOutcomeInterval(dynamic raw) {
  if (raw is! Map) return null;
  final m = Map<String, dynamic>.from(raw);
  if (!m.containsKey('start') && !m.containsKey('end')) return null;
  return DlcOutcomeIntervalBand.fromJson(m);
}

int _readInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}
