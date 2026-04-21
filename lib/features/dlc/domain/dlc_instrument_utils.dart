import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';

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

/// Short label for dropdowns (API id + optional oracle label).
String dlcInstrumentLabel(Map<String, dynamic> instrument) {
  final id = dlcInstrumentId(instrument) ?? '?';
  final oracle = instrument['oracle_label']?.toString().trim();
  if (oracle != null && oracle.isNotEmpty) {
    return '$id · $oracle';
  }
  return id;
}

/// Parsed expiry from coordinator [InstrumentResponse.expires_at] (ISO-8601).
DateTime? dlcInstrumentExpiresAt(Map<String, dynamic> instrument) {
  final raw = instrument['expires_at'];
  if (raw is String) return DateTime.tryParse(raw);
  return null;
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
