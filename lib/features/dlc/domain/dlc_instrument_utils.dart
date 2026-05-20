import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';

class DlcInstrumentMetadata {
  final String underlying;
  final String? expiryToken;
  final String? strike;
  final DlcOptionType? right;

  const DlcInstrumentMetadata({
    required this.underlying,
    required this.expiryToken,
    required this.strike,
    required this.right,
  });
}

/// Uses coordinator [InstrumentResponse.type] (`call` / `put`) when present.
bool dlcInstrumentMatchesOptionType(
  Map<String, dynamic> instrument,
  DlcOptionType optionType,
) {
  final raw = (instrument['type'] ?? '').toString().trim().toLowerCase();
  if (raw.isNotEmpty) {
    final isCall = raw == 'call' || raw == 'c';
    final isPut = raw == 'put' || raw == 'p';
    if (isCall || isPut) {
      return optionType == DlcOptionType.call ? isCall : isPut;
    }
  }
  final id = (instrument['instrument_id'] ?? instrument['id'] ?? '')
      .toString()
      .toUpperCase();
  if (optionType == DlcOptionType.call) {
    return id.endsWith('-C') || id.contains('CALL');
  }
  return id.endsWith('-P') || id.contains('PUT');
}

String? dlcInstrumentId(Map<String, dynamic> instrument) {
  final v = instrument['instrument_id'] ?? instrument['id'];
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

DlcInstrumentMetadata dlcInstrumentMetadata(Map<String, dynamic> instrument) {
  final id = dlcInstrumentId(instrument) ?? '';
  final parts = id.split('-');
  final rawType = (instrument['type'] ?? '').toString().trim().toLowerCase();
  DlcOptionType? right;
  if (rawType == 'call' || rawType == 'c') {
    right = DlcOptionType.call;
  } else if (rawType == 'put' || rawType == 'p') {
    right = DlcOptionType.put;
  } else if (parts.isNotEmpty) {
    final suffix = parts.last.toUpperCase();
    if (suffix == 'C' || suffix == 'CALL') {
      right = DlcOptionType.call;
    } else if (suffix == 'P' || suffix == 'PUT') {
      right = DlcOptionType.put;
    }
  }

  return DlcInstrumentMetadata(
    underlying: parts.isEmpty || parts.first.isEmpty ? 'BTC' : parts.first,
    expiryToken: parts.length > 1 ? parts[1] : null,
    strike: parts.length > 2 ? parts[2] : null,
    right: right,
  );
}

bool dlcInstrumentUsesStrikeTemplate(String? instrumentId) {
  return instrumentId != null && instrumentId.contains('-STRIKE-');
}

/// Strikes to show as orderbook rows for the selected template instrument.
List<double> dlcStrikesForOrderbook({
  required String? templateInstrumentId,
  required List<double> suggestedStrikePrices,
}) {
  final id = templateInstrumentId;
  if (id == null || id.isEmpty) return const [];
  if (dlcInstrumentUsesStrikeTemplate(id)) {
    final strikes = List<double>.from(suggestedStrikePrices)..sort();
    return strikes;
  }
  final parts = id.split('-');
  if (parts.length >= 3) {
    final token = parts[2];
    if (token != 'STRIKE') {
      final parsed = double.tryParse(token);
      if (parsed != null) return [parsed];
    }
  }
  return const [];
}

String dlcInstrumentIdWithStrike(String instrumentId, double? strikePrice) {
  if (!instrumentId.contains('-STRIKE-') || strikePrice == null) {
    return instrumentId;
  }
  return instrumentId.replaceFirst(
    '-STRIKE-',
    '-${dlcNormalizeStrikeToken(strikePrice)}-',
  );
}

/// Whole USD/BTC strike from a resolved instrument id, or null when unknown.
int? dlcStrikeUsdFromInstrumentId(String? instrumentId) {
  if (instrumentId == null || instrumentId.isEmpty) return null;
  final meta = dlcInstrumentMetadata(<String, dynamic>{
    'instrument_id': instrumentId,
  });
  final token = meta.strike;
  if (token == null || token.isEmpty || token.toUpperCase() == 'STRIKE') {
    return null;
  }
  final parsed = double.tryParse(token);
  if (parsed == null || parsed < 1) return null;
  return parsed.round();
}

String dlcNormalizeStrikeToken(double strike) {
  final rounded = strike.roundToDouble();
  if ((strike - rounded).abs() < 1e-9) {
    return rounded.toInt().toString();
  }
  return strike.toStringAsFixed(8).replaceFirst(RegExp(r'\.?0+$'), '');
}

/// Instrument id for UI display (hides `-STRIKE-` template placeholder).
String dlcInstrumentDisplayId(String? rawId) {
  if (rawId == null || rawId.isEmpty) return '-';
  return rawId.replaceAll('-STRIKE-', '-');
}

/// Short label for instrument dropdowns (id only, no oracle).
String dlcInstrumentLabel(Map<String, dynamic> instrument) {
  final id = dlcInstrumentDisplayId(dlcInstrumentId(instrument));
  if (isDlcInstrumentExpired(instrument)) {
    return '$id (expired)';
  }
  return id;
}

/// Parsed expiry from coordinator [InstrumentResponse.expires_at] (ISO-8601).
DateTime? dlcInstrumentExpiresAt(Map<String, dynamic> instrument) {
  final raw = instrument['expires_at'];
  if (raw is String) return DateTime.tryParse(raw);
  return null;
}

/// True when [expires_at] is present and not after the current instant (UTC).
bool isDlcInstrumentExpired(Map<String, dynamic> instrument) {
  final expiresAt = dlcInstrumentExpiresAt(instrument);
  if (expiresAt == null) return false;
  return !expiresAt.toUtc().isAfter(DateTime.now().toUtc());
}

/// Live instruments from a `GET /instruments` payload (client-side filter).
List<Map<String, dynamic>> dlcLiveInstruments(
  Iterable<Map<String, dynamic>> instruments,
) {
  return instruments
      .where((i) => !isDlcInstrumentExpired(i))
      .toList(growable: false);
}

/// Expired instruments from a `GET /instruments` payload (client-side filter).
List<Map<String, dynamic>> dlcExpiredInstruments(
  Iterable<Map<String, dynamic>> instruments,
) {
  return instruments
      .where(isDlcInstrumentExpired)
      .toList(growable: false);
}

/// Puts non-expired instruments first, then expired (for orderbook pickers).
List<Map<String, dynamic>> dlcSortInstrumentsLiveBeforeExpired(
  Iterable<Map<String, dynamic>> instruments,
) {
  final live = <Map<String, dynamic>>[];
  final expired = <Map<String, dynamic>>[];
  for (final instrument in instruments) {
    if (isDlcInstrumentExpired(instrument)) {
      expired.add(instrument);
    } else {
      live.add(instrument);
    }
  }
  return [...live, ...expired];
}

/// Find the instrument map for [instrumentId] in [instruments], or null.
Map<String, dynamic>? dlcInstrumentById(
  List<Map<String, dynamic>> instruments,
  String? instrumentId,
) {
  if (instrumentId == null) return null;
  for (final i in instruments) {
    if (dlcInstrumentId(i) == instrumentId) return i;
  }
  return null;
}
