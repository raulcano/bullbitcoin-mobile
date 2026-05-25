import 'package:bb_mobile/core/settings/data/settings_repository.dart';
import 'package:bb_mobile/core/settings/domain/repositories/settings_repository.dart'
    as domain;
import 'package:bb_mobile/core/storage/data/datasources/key_value_storage/key_value_storage_datasource.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bb_mobile/core/wallet/data/repositories/wallet_repository.dart';
import 'package:bb_mobile/core/wallet/domain/usecases/get_wallet_utxos_usecase.dart';
import 'package:bb_mobile/core/seed/data/repository/seed_repository.dart';
import 'package:bb_mobile/features/dlc/data/dlc_api_datasource.dart';
import 'package:bb_mobile/features/dlc/data/dlc_auth_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_idempotency_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_negotiation_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_order_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_repository.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_local_signer.dart';
import 'package:bb_mobile/features/dlc/presentation/dlc_cubit.dart';
import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';

class DlcLocator {
  static void setup(GetIt locator) {
    locator.registerLazySingleton<Dio>(() {
      final dio = Dio(
        BaseOptions(
          baseUrl: ApiServiceConstants.dlcCoordinatorBaseUrl.trim().replaceAll(
            RegExp(r'/+$'),
            '',
          ),
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          sendTimeout: const Duration(seconds: 8),
          // Uvicorn/httptools can mis-parse back-to-back POSTs on a keep-alive
          // connection (known issue; logs "Invalid HTTP request received").
          persistentConnection: false,
        ),
      );
      final partner = ApiServiceConstants.dlcCoordinatorPartnerToken.trim();
      if (partner.isNotEmpty) {
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              options.headers['X-Partner-Token'] = partner;
              handler.next(options);
            },
          ),
        );
      }
      return dio;
    }, instanceName: 'dlcCoordinatorDio');

    locator.registerLazySingleton<DlcApiDatasource>(
      () => DlcApiDatasource(
        dio: locator<Dio>(instanceName: 'dlcCoordinatorDio'),
        settingsRepository: locator<domain.SettingsRepository>(),
      ),
    );

    locator.registerLazySingleton<DlcAuthStorage>(
      () => DlcAuthStorage(
        secureStorage: locator<KeyValueStorageDatasource<String>>(
          instanceName: LocatorInstanceNameConstants.secureStorageDatasource,
        ),
      ),
    );

    locator.registerLazySingleton<DlcIdempotencyStorage>(
      () => DlcIdempotencyStorage(
        secureStorage: locator<KeyValueStorageDatasource<String>>(
          instanceName: LocatorInstanceNameConstants.secureStorageDatasource,
        ),
      ),
    );

    locator.registerLazySingleton<DlcOrderStorage>(
      () => DlcOrderStorage(
        secureStorage: locator<KeyValueStorageDatasource<String>>(
          instanceName: LocatorInstanceNameConstants.secureStorageDatasource,
        ),
      ),
    );

    locator.registerLazySingleton<DlcNegotiationStorage>(
      () => DlcNegotiationStorage(
        secureStorage: locator<KeyValueStorageDatasource<String>>(
          instanceName: LocatorInstanceNameConstants.secureStorageDatasource,
        ),
      ),
    );

    locator.registerLazySingleton<DlcLocalSigner>(
      () => DlcLocalSigner(
        walletRepository: locator<WalletRepository>(),
        seedRepository: locator<SeedRepository>(),
      ),
    );

    locator.registerLazySingleton<DlcRepository>(
      () => DlcRepository(
        settingsRepository: locator<SettingsRepository>(),
        datasource: locator<DlcApiDatasource>(),
        authStorage: locator<DlcAuthStorage>(),
        idempotencyStorage: locator<DlcIdempotencyStorage>(),
        orderStorage: locator<DlcOrderStorage>(),
        negotiationStorage: locator<DlcNegotiationStorage>(),
        localSigner: locator<DlcLocalSigner>(),
        getWalletUtxosUsecase: locator<GetWalletUtxosUsecase>(),
      ),
    );

    // Lazy singleton so the active DLC wallet session, orders, and the
    // background polling timer survive navigation away from /dlcs and back.
    // The DlcRouter pairs this with `BlocProvider.value` so the route does
    // not close the cubit when the page is popped.
    locator.registerLazySingleton<DlcCubit>(
      () => DlcCubit(repository: locator<DlcRepository>()),
    );
  }
}
