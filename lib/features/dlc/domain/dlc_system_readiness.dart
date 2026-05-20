/// Parsed `GET /auth/system-readiness` payload (coordinator chain backend model).
class DlcDependencyStatus {
  const DlcDependencyStatus({
    required this.ok,
    required this.latencyMs,
    this.error,
    this.details,
  });

  final bool ok;
  final int latencyMs;
  final String? error;
  final Map<String, dynamic>? details;

  factory DlcDependencyStatus.fromJson(Map<String, dynamic> json) {
    final detailsRaw = json['details'];
    return DlcDependencyStatus(
      ok: json['ok'] == true,
      latencyMs: (json['latency_ms'] as num?)?.toInt() ?? 0,
      error: json['error'] as String?,
      details: detailsRaw is Map
          ? Map<String, dynamic>.from(detailsRaw)
          : null,
    );
  }

  static const unavailable = DlcDependencyStatus(ok: false, latencyMs: 0);
}

class DlcSystemReadiness {
  const DlcSystemReadiness({
    required this.network,
    required this.isRegtest,
    required this.tradingReady,
    required this.canCreateFundedWallet,
    required this.blockers,
    required this.chainBackend,
    this.regtestMining,
  });

  final String network;
  final bool isRegtest;
  final bool tradingReady;
  final bool canCreateFundedWallet;
  final List<String> blockers;
  final DlcDependencyStatus chainBackend;
  final DlcDependencyStatus? regtestMining;

  /// Runtime chain operations (UTXO lookup, broadcast, confirmations).
  bool get isChainBackendOk => chainBackend.ok;

  /// Main flag for whether the coordinator allows trading.
  bool get canTrade => tradingReady && chainBackend.ok;

  static DlcSystemReadiness? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    final chainRaw = json['chain_backend'];
    final chainBackend = chainRaw is Map<String, dynamic>
        ? DlcDependencyStatus.fromJson(chainRaw)
        : chainRaw is Map
        ? DlcDependencyStatus.fromJson(Map<String, dynamic>.from(chainRaw))
        : DlcDependencyStatus.unavailable;

    final regtestRaw = json['regtest_mining'];
    DlcDependencyStatus? regtestMining;
    if (regtestRaw is Map<String, dynamic>) {
      regtestMining = DlcDependencyStatus.fromJson(regtestRaw);
    } else if (regtestRaw is Map) {
      regtestMining = DlcDependencyStatus.fromJson(
        Map<String, dynamic>.from(regtestRaw),
      );
    }

    final blockersRaw = json['blockers'];
    final blockers = blockersRaw is List
        ? blockersRaw.map((e) => e.toString()).toList(growable: false)
        : const <String>[];

    return DlcSystemReadiness(
      network: json['network']?.toString() ?? '',
      isRegtest: json['is_regtest'] == true,
      tradingReady: json['trading_ready'] == true,
      canCreateFundedWallet: json['can_create_funded_wallet'] == true,
      blockers: blockers,
      chainBackend: chainBackend,
      regtestMining: regtestMining,
    );
  }
}

/// Whether the coordinator [network] string is a non-mainnet deployment.
bool dlcCoordinatorNetworkIsTestnet({
  required String network,
  required bool isRegtest,
}) {
  if (isRegtest) return true;
  final normalized = network.trim().toLowerCase();
  if (normalized.isEmpty) return false;
  if (normalized == 'mainnet' || normalized == 'bitcoin') return false;
  return normalized.contains('test') ||
      normalized == 'signet' ||
      normalized == 'regtest';
}
