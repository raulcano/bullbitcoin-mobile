import 'package:bb_mobile/core/settings/data/settings_repository.dart';
import 'package:bb_mobile/core/settings/domain/repositories/settings_repository.dart'
    as domain;
import 'package:bb_mobile/core/storage/data/datasources/key_value_storage/key_value_storage_datasource.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bb_mobile/core/wallet/data/repositories/wallet_repository.dart';
import 'package:bb_mobile/core/seed/data/repository/seed_repository.dart';
import 'package:bb_mobile/features/dlc/data/dlc_api_datasource.dart';
import 'package:bb_mobile/features/dlc/data/dlc_auth_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_repository.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_local_signer.dart';
import 'package:bb_mobile/features/dlc/presentation/dlc_cubit.dart';
import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';

class DlcLocator {
  static void setup(GetIt locator) {
    locator.registerLazySingleton<Dio>(
      () => Dio(
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
      ),
      instanceName: 'dlcCoordinatorDio',
    );

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
        localSigner: locator<DlcLocalSigner>(),
      ),
    );

    locator.registerFactory<DlcCubit>(
      () => DlcCubit(repository: locator<DlcRepository>()),
    );
  }
}
