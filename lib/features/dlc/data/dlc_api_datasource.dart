import 'package:bb_mobile/core/settings/domain/repositories/settings_repository.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:dio/dio.dart';

class DlcApiDatasource {
  final Dio _dio;
  final SettingsRepository _settingsRepository;

  DlcApiDatasource({
    required Dio dio,
    required SettingsRepository settingsRepository,
  }) : _dio = dio,
       _settingsRepository = settingsRepository;

  Future<void> _ensureBaseUrl() async {
    final settings = await _settingsRepository.fetch();
    final next = ApiServiceConstants.dlcCoordinatorUrlForEnvironment(
      settings.environment,
    );
    if (_dio.options.baseUrl != next) {
      _dio.options.baseUrl = next;
    }
  }

  Future<Map<String, dynamic>> createNonce() async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.post('/auth/nonce', data: <String, dynamic>{});
      return (response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> registerWallet({
    required String xpub,
    required String nonce,
    required String xpubSignature,
    required String label,
    required List<Map<String, dynamic>> utxos,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.post(
        '/auth/wallet',
        data: {
          'xpub': xpub,
          'nonce': nonce,
          'xpub_signature': xpubSignature,
          'label': label,
          'utxos': utxos,
        },
      );
      return (response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<List<dynamic>> listInstruments() async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get('/instruments/non-expired');
      return (response.data as List<dynamic>? ?? const []);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> createOrder({
    required String token,
    required Map<String, dynamic> payload,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.post(
        '/orders',
        data: payload,
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return (response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<List<dynamic>> listOrders({required String token}) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get(
        '/orders',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return (response.data as List<dynamic>? ?? const []);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> getOrder({
    required String token,
    required String orderId,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get(
        '/orders/$orderId',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return (response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> getWallet({
    required String token,
    required String walletId,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get(
        '/auth/wallet/$walletId',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return (response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  /// GET /auth/wallet/{id} — returns `null` when the token is expired or denied
  /// (401 / 403 / 404) so the app can clear stored credentials without treating
  /// that as a hard error. Other failures still throw.
  Future<Map<String, dynamic>?> getWalletOrNullOnAuthFailure({
    required String token,
    required String walletId,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get(
        '/auth/wallet/$walletId',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return null;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403 || code == 404) {
        return null;
      }
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> acceptContext({
    required String token,
    required String orderId,
    required String fundingPubkeyHex,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.post(
        '/orders/$orderId/accept-context',
        data: {'funding_pubkey_hex': fundingPubkeyHex},
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return (response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> acceptMatch({
    required String token,
    required String orderId,
    required Map<String, dynamic> payload,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.post(
        '/orders/$orderId/accept-match',
        data: payload,
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return (response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> signContext({
    required String token,
    required String dlcId,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get(
        '/dlcs/$dlcId/sign-context',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return (response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> signDlc({
    required String token,
    required String dlcId,
    required Map<String, dynamic> payload,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.post(
        '/dlcs/$dlcId/sign',
        data: payload,
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return (response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> getDlcStatus({
    required String token,
    required String dlcId,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get(
        '/dlcs/$dlcId/settlement-status',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return (response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> getOrderbook({
    required String instrumentId,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get('/orderbook/$instrumentId');
      return (response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  String _readApiError(DioException exception) {
    final data = exception.response?.data;
    if (data is Map<String, dynamic>) {
      final detail = data['detail'];
      if (detail is Map<String, dynamic>) {
        final reason = detail['reason']?.toString();
        final message = detail['message']?.toString();
        if (reason != null && message != null) {
          return '$reason: $message';
        }
        if (message != null) return message;
      }
      if (detail is String) return detail;
      if (data['message'] is String) return data['message'] as String;
    }
    return exception.message ?? 'DLC API request failed';
  }
}
