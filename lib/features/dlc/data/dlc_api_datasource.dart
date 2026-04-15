import 'package:dio/dio.dart';

class DlcApiDatasource {
  final Dio _dio;

  DlcApiDatasource({required Dio dio}) : _dio = dio;

  Future<Map<String, dynamic>> createNonce() async {
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

  Future<Map<String, dynamic>> acceptContext({
    required String token,
    required String orderId,
    required String fundingPubkeyHex,
  }) async {
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
