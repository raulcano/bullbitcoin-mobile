import 'package:bb_mobile/core/dlc/data/repository/dlc_signing_repository_impl.dart';
import 'package:bb_mobile/core/dlc/data/services/adaptor_signing_service.dart';
import 'package:bb_mobile/core/dlc/data/services/cet_message_hash_service.dart';
import 'package:bb_mobile/core/dlc/domain/ports/dlc_signing_repository.dart';
import 'package:bb_mobile/core/dlc/domain/usecases/decrypt_adaptor_signature_usecase.dart';
import 'package:bb_mobile/core/dlc/domain/usecases/recover_decryption_key_usecase.dart';
import 'package:bb_mobile/core/dlc/domain/usecases/sign_all_cets_with_adaptor_usecase.dart';
import 'package:bb_mobile/core/dlc/domain/usecases/sign_cet_with_adaptor_usecase.dart';
import 'package:bb_mobile/core/dlc/domain/usecases/verify_adaptor_signature_usecase.dart';
import 'package:get_it/get_it.dart';

class DlcLocator {
  static void registerRepositories(GetIt locator) {
    locator.registerLazySingleton<DlcSigningRepository>(
      () => DlcSigningRepositoryImpl(
        signingService: AdaptorSigningService(
          cetHashService: CetMessageHashService(),
        ),
      ),
    );
  }

  static void registerUsecases(GetIt locator) {
    locator.registerFactory(
      () => SignCetWithAdaptorUsecase(repository: locator<DlcSigningRepository>()),
    );
    locator.registerFactory(
      () => SignAllCetsWithAdaptorUsecase(repository: locator<DlcSigningRepository>()),
    );
    locator.registerFactory(
      () => VerifyAdaptorSignatureUsecase(repository: locator<DlcSigningRepository>()),
    );
    locator.registerFactory(
      () => DecryptAdaptorSignatureUsecase(repository: locator<DlcSigningRepository>()),
    );
    locator.registerFactory(
      () => RecoverDecryptionKeyUsecase(repository: locator<DlcSigningRepository>()),
    );
  }
}
