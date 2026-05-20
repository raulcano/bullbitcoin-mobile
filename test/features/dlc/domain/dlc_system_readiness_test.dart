import 'package:bb_mobile/features/dlc/domain/dlc_system_readiness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DlcSystemReadiness', () {
    test('tryParse reads chain_backend and trading_ready', () {
      final readiness = DlcSystemReadiness.tryParse({
        'network': 'testnet3',
        'is_regtest': false,
        'trading_ready': true,
        'can_create_funded_wallet': false,
        'blockers': [],
        'chain_backend': {
          'ok': true,
          'latency_ms': 12,
          'error': null,
          'details': {'provider_network': 'testnet'},
        },
        'regtest_mining': null,
      });

      expect(readiness, isNotNull);
      expect(readiness!.network, 'testnet3');
      expect(readiness.isChainBackendOk, isTrue);
      expect(readiness.canTrade, isTrue);
      expect(readiness.regtestMining, isNull);
    });

    test('canTrade is false when chain_backend is unhealthy', () {
      final readiness = DlcSystemReadiness.tryParse({
        'network': 'testnet3',
        'is_regtest': false,
        'trading_ready': true,
        'can_create_funded_wallet': false,
        'blockers': [],
        'chain_backend': {'ok': false, 'latency_ms': 0},
      });

      expect(readiness!.canTrade, isFalse);
    });

    test('canTrade is false when trading_ready is false', () {
      final readiness = DlcSystemReadiness.tryParse({
        'network': 'mainnet',
        'is_regtest': false,
        'trading_ready': false,
        'blockers': ['oracle offline'],
        'chain_backend': {'ok': true, 'latency_ms': 5},
      });

      expect(readiness!.canTrade, isFalse);
      expect(readiness.blockers, ['oracle offline']);
    });
  });

  group('dlcCoordinatorNetworkIsTestnet', () {
    test('treats testnet3 and signet as testnet', () {
      expect(
        dlcCoordinatorNetworkIsTestnet(network: 'testnet3', isRegtest: false),
        isTrue,
      );
      expect(
        dlcCoordinatorNetworkIsTestnet(network: 'signet', isRegtest: false),
        isTrue,
      );
      expect(
        dlcCoordinatorNetworkIsTestnet(network: 'mainnet', isRegtest: false),
        isFalse,
      );
    });
  });
}
