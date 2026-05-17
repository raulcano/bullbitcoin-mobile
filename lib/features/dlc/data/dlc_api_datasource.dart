import 'package:bb_mobile/core/settings/domain/repositories/settings_repository.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:dio/dio.dart';

class DlcApiException implements Exception {
  final int? statusCode;
  final String message;
  final bool isTimeout;
  final bool isConnectionError;

  const DlcApiException({
    required this.statusCode,
    required this.message,
    required this.isTimeout,
    this.isConnectionError = false,
  });

  @override
  String toString() {
    final prefix = statusCode == null ? '' : 'HTTP $statusCode: ';
    return '$prefix$message';
  }
}

class DlcApiDatasource {
  final Dio _dio;
  final SettingsRepository _settingsRepository;

  DlcApiDatasource({
    required Dio dio,
    required SettingsRepository settingsRepository,
  }) : _dio = dio,
       _settingsRepository = settingsRepository {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onError: (exception, handler) async {
          if (exception.requestOptions.extra['dlc_skip_backup'] == true) {
            handler.next(exception);
            return;
          }

          if (!_shouldTryBackup(exception)) {
            handler.next(exception);
            return;
          }

          final settings = await _settingsRepository.fetch();
          final backup =
              ApiServiceConstants.dlcCoordinatorBackupUrlForEnvironment(
                settings.environment,
              );
          if (backup == null) {
            handler.next(exception);
            return;
          }

          final request = exception.requestOptions;
          if (request.extra['dlc_backup_attempt'] == true) {
            handler.next(exception);
            return;
          }

          try {
            final retry = request.copyWith(
              baseUrl: backup,
              extra: {...request.extra, 'dlc_backup_attempt': true},
            );
            _dio.options.baseUrl = backup;
            final response = await _dio.fetch<dynamic>(retry);
            handler.resolve(response);
          } on DioException catch (backupException) {
            handler.next(backupException);
          } catch (_) {
            handler.next(exception);
          }
        },
      ),
    );
  }

  Future<void> _ensureBaseUrl() async {
    final settings = await _settingsRepository.fetch();
    final next = ApiServiceConstants.dlcCoordinatorUrlForEnvironment(
      settings.environment,
    );
    if (_dio.options.baseUrl != next) {
      _dio.options.baseUrl = next;
    }
  }

  bool _shouldTryBackup(DioException exception) {
    return _isTimeout(exception) ||
        exception.type == DioExceptionType.connectionError ||
        exception.type == DioExceptionType.unknown;
  }

  bool _isTimeout(DioException exception) {
    return exception.type == DioExceptionType.connectionTimeout ||
        exception.type == DioExceptionType.sendTimeout ||
        exception.type == DioExceptionType.receiveTimeout;
  }

  Future<double> getBtcUsdSpotPrice() async {
    final url = ApiServiceConstants.dlcBtcUsdTickerUrl.trim();
    if (url.isEmpty) {
      throw Exception('DLC_BTC_USD_TICKER_URL is not configured.');
    }
    try {
      final response = await Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 6),
          sendTimeout: const Duration(seconds: 6),
        ),
      ).get<dynamic>(url);
      return _readTickerPrice(response.data);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  double _readTickerPrice(dynamic data) {
    double? readNum(dynamic value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value.replaceAll(',', ''));
      return null;
    }

    if (data is Map) {
      final directKeys = ['price', 'amount', 'last', 'rate'];
      for (final key in directKeys) {
        final value = readNum(data[key]);
        if (value != null) return value;
      }

      final nestedData = data['data'];
      if (nestedData is Map) {
        for (final key in directKeys) {
          final value = readNum(nestedData[key]);
          if (value != null) return value;
        }
      }

      final bitcoin = data['bitcoin'];
      if (bitcoin is Map) {
        final value = readNum(bitcoin['usd']);
        if (value != null) return value;
      }

      final usd = data['USD'];
      if (usd is Map) {
        for (final key in directKeys) {
          final value = readNum(usd[key]);
          if (value != null) return value;
        }
      }
    }
    throw Exception('Ticker response did not contain a BTC/USD price.');
  }

  Future<Map<String, dynamic>> createNonce() async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.post(
        '/auth/nonce',
        data: <String, dynamic>{},
      );
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

  Future<Map<String, dynamic>> getSystemReadiness() async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get('/auth/system-readiness');
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return const {};
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> simulateOptionPayout({
    required String token,
    required Map<String, dynamic> payload,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.post(
        '/orders/option-payout-simulation',
        data: payload,
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return const {};
    } on DioException catch (e) {
      throw DlcApiException(
        statusCode: e.response?.statusCode,
        message: _readApiError(e),
        isTimeout: _isTimeout(e),
      );
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
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          // Offer build + match can exceed the default 8s coordinator timeout.
          receiveTimeout: const Duration(seconds: 90),
          sendTimeout: const Duration(seconds: 30),
          extra: const {'dlc_skip_backup': true},
        ),
      );
      return (response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw DlcApiException(
        statusCode: e.response?.statusCode,
        message: _readApiError(e),
        isTimeout: _isTimeout(e),
        isConnectionError: e.type == DioExceptionType.connectionError,
      );
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

  Future<Map<String, dynamic>> cancelOrder({
    required String token,
    required String orderId,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.post(
        '/orders/$orderId/cancel',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return const {};
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  /// Client-driven UTXO set update (normal balance path; not xpub scan).
  Future<Map<String, dynamic>> syncWalletUtxos({
    required String token,
    required String walletId,
    required List<Map<String, dynamic>> utxos,
    String? nonce,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.post(
        '/auth/wallet/$walletId/sync-utxos',
        data: {
          if (nonce != null && nonce.isNotEmpty) 'nonce': nonce,
          'utxos': utxos,
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return const {};
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

  Future<Map<String, dynamic>> getDlc({
    required String token,
    required String dlcId,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get(
        '/dlcs/$dlcId',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return (response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> getDlcFundingTransaction({
    required String token,
    required String dlcId,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get(
        '/dlcs/$dlcId/funding-transaction',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return const {};
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> getDlcPayoutData({
    required String token,
    required String dlcId,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get(
        '/dlcs/$dlcId/payout-data',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return const {};
    } on DioException catch (e) {
      throw Exception(_readApiError(e));
    }
  }

  Future<Map<String, dynamic>> getDlcAttestation({
    required String token,
    required String dlcId,
  }) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get(
        '/dlcs/$dlcId/attestation',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return const {};
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
      if (detail is List) {
        final messages = detail
            .map((item) {
              if (item is Map) {
                final loc = item['loc'] is List
                    ? (item['loc'] as List).join('.')
                    : item['loc']?.toString();
                final msg = item['msg']?.toString();
                if (loc != null && msg != null) return '$loc: $msg';
                return msg ?? item.toString();
              }
              return item.toString();
            })
            .join('; ');
        if (messages.isNotEmpty) return messages;
      }
      if (detail is String) return detail;
      if (data['message'] is String) return data['message'] as String;
    }
    final code = exception.response?.statusCode;
    final prefix = code == null ? '' : 'HTTP $code: ';
    return '$prefix${exception.message ?? 'DLC API request failed'}';
  }
}
