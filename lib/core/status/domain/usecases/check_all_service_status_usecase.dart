import 'dart:io';

import 'package:bb_mobile/core/ark/entities/ark_wallet.dart';
import 'package:bb_mobile/core/ark/usecases/fetch_ark_secret_usecase.dart';
import 'package:bb_mobile/core/exchange/domain/repositories/exchange_rate_repository.dart';
import 'package:bb_mobile/core/fees/data/fees_repository.dart';
import 'package:bb_mobile/core/payjoin/domain/repositories/payjoin_repository.dart';
import 'package:bb_mobile/core/recoverbull/data/repository/recoverbull_repository.dart';
import 'package:bb_mobile/core/settings/data/settings_repository.dart';
import 'package:bb_mobile/core/status/domain/entity/service_status.dart';
import 'package:bb_mobile/core/status/domain/ports/electrum_connectivity_port.dart';
import 'package:bb_mobile/core/swaps/data/repository/boltz_swap_repository.dart';
import 'package:bb_mobile/core/swaps/domain/entity/swap.dart';
import 'package:bb_mobile/core/tor/data/usecases/tor_status_usecase.dart';
import 'package:bb_mobile/core/tor/tor_status.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bb_mobile/core/utils/logger.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_system_readiness.dart';
import 'package:bb_mobile/core/wallet/data/repositories/wallet_repository.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet.dart';
import 'package:dio/dio.dart';

class CheckAllServiceStatusUsecase {
  final ElectrumConnectivityPort _electrumConnectivityPort;
  final BoltzSwapRepository _mainnetBoltzSwapRepository;
  final BoltzSwapRepository _testnetBoltzSwapRepository;
  final ExchangeRateRepository _exchangeRateRepository;
  final PayjoinRepository _payjoinRepository;
  final FeesRepository _feesRepository;
  final RecoverBullRepository _recoverBullRepository;
  final WalletRepository _walletRepository;
  final SettingsRepository _settingsRepository;
  final FetchArkSecretUsecase _fetchArkSecretUsecase;
  final TorStatusUsecase _torStatusUsecase;

  CheckAllServiceStatusUsecase({
    required ElectrumConnectivityPort electrumConnectivityPort,
    required BoltzSwapRepository mainnetBoltzSwapRepository,
    required BoltzSwapRepository testnetBoltzSwapRepository,
    required ExchangeRateRepository exchangeRateRepository,
    required PayjoinRepository payjoinRepository,
    required FeesRepository feesRepository,
    required RecoverBullRepository recoverBullRepository,
    required WalletRepository walletRepository,
    required SettingsRepository settingsRepository,
    required FetchArkSecretUsecase fetchArkSecretUsecase,
    required TorStatusUsecase torStatusUsecase,
  }) : _electrumConnectivityPort = electrumConnectivityPort,
       _mainnetBoltzSwapRepository = mainnetBoltzSwapRepository,
       _testnetBoltzSwapRepository = testnetBoltzSwapRepository,
       _exchangeRateRepository = exchangeRateRepository,
       _payjoinRepository = payjoinRepository,
       _feesRepository = feesRepository,
       _recoverBullRepository = recoverBullRepository,
       _walletRepository = walletRepository,
       _settingsRepository = settingsRepository,
       _fetchArkSecretUsecase = fetchArkSecretUsecase,
       _torStatusUsecase = torStatusUsecase;

  Future<AllServicesStatus> execute({required Network network}) async {
    final now = DateTime.now();

    try {
      final results = await Future.wait([
        _checkInternetConnection(),
        _checkBitcoinElectrumServer(network),
        _checkLiquidElectrumServer(network),
        _checkBoltzService(network),
        _checkPayjoinService(),
        _checkPricerService(network),
        _checkMempoolService(network),
        _checkDlcApiService(),
        _checkTorConnection(),
        _checkRecoverbullConnection(),
        _checkArkConnection(),
      ]);

      return AllServicesStatus(
        internetConnection: results[0],
        bitcoinElectrum: results[1],
        liquidElectrum: results[2],
        boltz: results[3],
        payjoin: results[4],
        pricer: results[5],
        mempool: results[6],
        dlcApi: results[7],
        tor: results[8],
        recoverbull: results[9],
        ark: results[10],
        lastChecked: now,
      );
    } catch (e) {
      log.severe(
        message: 'Error checking service statuses',
        error: e,
        trace: StackTrace.current,
      );
      return _createUnknownStatus(now);
    }
  }

  Future<ServiceStatusInfo> _checkBitcoinElectrumServer(Network network) async {
    try {
      // Check Bitcoin Electrum servers
      final hasOnlineServers = await _electrumConnectivityPort
          .checkServersInUseAreOnlineForNetwork(
            network.isTestnet ? Network.bitcoinTestnet : Network.bitcoinMainnet,
          );

      return ServiceStatusInfo(
        status: hasOnlineServers ? ServiceStatus.online : ServiceStatus.offline,
        name: 'Bitcoin Electrum',
        lastChecked: DateTime.now(),
      );
    } catch (e) {
      return ServiceStatusInfo(
        status: ServiceStatus.offline,
        name: 'Bitcoin Electrum',
        lastChecked: DateTime.now(),
      );
    }
  }

  Future<ServiceStatusInfo> _checkLiquidElectrumServer(Network network) async {
    try {
      final hasOnlineServers = await _electrumConnectivityPort
          .checkServersInUseAreOnlineForNetwork(
            network.isTestnet ? Network.liquidTestnet : Network.liquidMainnet,
          );

      return ServiceStatusInfo(
        status: hasOnlineServers ? ServiceStatus.online : ServiceStatus.offline,

        name: 'Liquid Electrum',
        lastChecked: DateTime.now(),
      );
    } catch (e) {
      return ServiceStatusInfo(
        status: ServiceStatus.offline,
        name: 'Liquid Electrum',
        lastChecked: DateTime.now(),
      );
    }
  }

  Future<ServiceStatusInfo> _checkBoltzService(Network network) async {
    try {
      final boltzRepository = network == Network.bitcoinMainnet
          ? _mainnetBoltzSwapRepository
          : _testnetBoltzSwapRepository;

      await boltzRepository.updateSwapLimitsAndFees(
        SwapType.bitcoinToLightning,
      );

      return ServiceStatusInfo(
        status: ServiceStatus.online,
        name: 'Boltz',
        lastChecked: DateTime.now(),
      );
    } catch (e) {
      return ServiceStatusInfo(
        status: ServiceStatus.offline,
        name: 'Boltz',
        lastChecked: DateTime.now(),
      );
    }
  }

  Future<ServiceStatusInfo> _checkPayjoinService() async {
    try {
      final isHealthy = await _payjoinRepository.checkOhttpRelayHealth();

      return ServiceStatusInfo(
        status: isHealthy ? ServiceStatus.online : ServiceStatus.offline,
        name: 'Payjoin',
        lastChecked: DateTime.now(),
      );
    } catch (e) {
      return ServiceStatusInfo(
        status: ServiceStatus.offline,
        name: 'Payjoin',
        lastChecked: DateTime.now(),
      );
    }
  }

  Future<ServiceStatusInfo> _checkPricerService(Network network) async {
    try {
      final price = await _exchangeRateRepository.getCurrencyValue(
        amountSat: BigInt.from(100000000), // 1 BTC in sats
        currency: 'USD',
      );

      return ServiceStatusInfo(
        status: price > 0 ? ServiceStatus.online : ServiceStatus.offline,
        name: 'Pricer',
        lastChecked: DateTime.now(),
      );
    } catch (e) {
      return ServiceStatusInfo(
        status: ServiceStatus.offline,
        name: 'Pricer',
        lastChecked: DateTime.now(),
      );
    }
  }

  Future<ServiceStatusInfo> _checkMempoolService(Network network) async {
    try {
      // Test mempool connectivity by getting fees
      await _feesRepository.getNetworkFees(network: network);

      return ServiceStatusInfo(
        status: ServiceStatus.online,
        name: 'Mempool',
        lastChecked: DateTime.now(),
      );
    } catch (e) {
      return ServiceStatusInfo(
        status: ServiceStatus.offline,
        name: 'Mempool',
        lastChecked: DateTime.now(),
      );
    }
  }

  Future<ServiceStatusInfo> _checkDlcApiService() async {
    try {
      final settings = await _settingsRepository.fetch();
      final baseUrl = ApiServiceConstants.dlcCoordinatorUrlForEnvironment(
        settings.environment,
      );
      final dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
      );

      final partner = ApiServiceConstants.dlcCoordinatorPartnerToken.trim();
      final response = await dio.get(
        '/auth/system-readiness',
        options: Options(
          headers: partner.isEmpty ? null : {'X-Partner-Token': partner},
        ),
      );
      final data = response.data;
      final readiness = data is Map<String, dynamic>
          ? DlcSystemReadiness.tryParse(data)
          : data is Map
          ? DlcSystemReadiness.tryParse(Map<String, dynamic>.from(data))
          : null;
      final isReady = readiness?.canTrade ?? false;

      return ServiceStatusInfo(
        status: isReady ? ServiceStatus.online : ServiceStatus.offline,
        name: 'DLC API',
        lastChecked: DateTime.now(),
      );
    } catch (e) {
      return ServiceStatusInfo(
        status: ServiceStatus.offline,
        name: 'DLC API',
        lastChecked: DateTime.now(),
      );
    }
  }

  Future<ServiceStatusInfo> _checkInternetConnection() async {
    try {
      final result = await InternetAddress.lookup('bullbitcoin.com');
      final isConnected = result.isNotEmpty && result[0].rawAddress.isNotEmpty;

      return ServiceStatusInfo(
        status: isConnected ? ServiceStatus.online : ServiceStatus.offline,
        name: 'Internet Connection',
        lastChecked: DateTime.now(),
      );
    } catch (e) {
      return ServiceStatusInfo(
        status: ServiceStatus.offline,
        name: 'Internet Connection',
        lastChecked: DateTime.now(),
      );
    }
  }

  Future<ServiceStatusInfo> _checkTorConnection() async {
    var status = ServiceStatusInfo(
      status: ServiceStatus.unknown,
      name: 'Tor',
      lastChecked: DateTime.now(),
    );

    final torStatus = await _torStatusUsecase.execute();
    switch (torStatus) {
      case TorStatus.online:
        status = status.copyWith(status: ServiceStatus.online);
      case TorStatus.offline:
        status = status.copyWith(status: ServiceStatus.offline);
      default:
        status = status.copyWith(status: ServiceStatus.unknown);
    }
    return status;
  }

  Future<ServiceStatusInfo> _checkRecoverbullConnection() async {
    var status = ServiceStatusInfo(
      status: ServiceStatus.unknown,
      name: 'Recoverbull',
      lastChecked: DateTime.now(),
    );

    final isTorRequired = await _walletRepository.isTorRequired();
    final torStatus = await _torStatusUsecase.execute();
    if (isTorRequired && torStatus == TorStatus.online) {
      try {
        await _recoverBullRepository.checkConnection();
        status = status.copyWith(status: ServiceStatus.online);
      } catch (e) {
        status = status.copyWith(status: ServiceStatus.offline);
      }
    }

    return status;
  }

  Future<ServiceStatusInfo> _checkArkConnection() async {
    var status = ServiceStatusInfo(
      status: ServiceStatus.unknown,
      name: 'Ark',
      lastChecked: DateTime.now(),
    );

    try {
      final settings = await _settingsRepository.fetch();
      if (settings.isDevModeEnabled != true) return status;

      final arkSecretKey = await _fetchArkSecretUsecase.execute();
      if (arkSecretKey == null) return status;

      await ArkWalletEntity.init(secretKey: arkSecretKey);

      status = status.copyWith(status: ServiceStatus.online);
    } catch (e) {
      status = status.copyWith(status: ServiceStatus.offline);
    }

    return status;
  }

  AllServicesStatus _createUnknownStatus(DateTime now) {
    return AllServicesStatus(
      internetConnection: ServiceStatusInfo(
        status: ServiceStatus.unknown,
        name: 'Internet Connection',
        lastChecked: now,
      ),
      bitcoinElectrum: ServiceStatusInfo(
        status: ServiceStatus.unknown,
        name: 'Bitcoin Electrum',
        lastChecked: now,
      ),
      liquidElectrum: ServiceStatusInfo(
        status: ServiceStatus.unknown,
        name: 'Liquid Electrum',
        lastChecked: now,
      ),
      boltz: ServiceStatusInfo(
        status: ServiceStatus.unknown,
        name: 'Boltz',
        lastChecked: now,
      ),
      payjoin: ServiceStatusInfo(
        status: ServiceStatus.unknown,
        name: 'Payjoin',
        lastChecked: now,
      ),
      pricer: ServiceStatusInfo(
        status: ServiceStatus.unknown,
        name: 'Pricer',
        lastChecked: now,
      ),
      mempool: ServiceStatusInfo(
        status: ServiceStatus.unknown,
        name: 'Mempool',
        lastChecked: now,
      ),
      dlcApi: ServiceStatusInfo(
        status: ServiceStatus.unknown,
        name: 'DLC API',
        lastChecked: now,
      ),
      lastChecked: now,
    );
  }

}
