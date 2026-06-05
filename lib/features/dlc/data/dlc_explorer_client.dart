import 'package:dio/dio.dart';
import 'package:webview_flutter/webview_flutter.dart';

class DlcExplorerLoginResult {
  const DlcExplorerLoginResult({
    required this.finalUrl,
    required this.cookies,
    this.html,
  });

  final Uri finalUrl;
  final List<WebViewCookie> cookies;
  final String? html;
}

class DlcExplorerClient {
  DlcExplorerClient({Dio? dio}) : _dio = dio ?? _createDio();

  final Dio _dio;

  static Dio _createDio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 15),
        // Same uvicorn keep-alive workaround as the coordinator Dio client.
        persistentConnection: false,
        headers: const {'Connection': 'close'},
      ),
    );
  }

  /// POST login form to the user dashboard; returns cookies and page to load.
  Future<DlcExplorerLoginResult> login({
    required String dashboardUrl,
    required String walletToken,
    required String dlcId,
  }) async {
    final postUri = Uri.parse(dashboardUrl);

    try {
      final response = await _dio.post<String>(
        dashboardUrl,
        data: {
          'wallet_token': walletToken,
          'dlc_id': dlcId,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final cookies = _webViewCookiesFromResponse(
        response: response,
        baseUri: postUri,
      );

      final status = response.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        final location = response.headers.value('location');
        if (location == null || location.trim().isEmpty) {
          throw DlcExplorerException(
            'Dashboard login redirected without a Location header.',
          );
        }
        final target = postUri.resolve(location.trim());
        return DlcExplorerLoginResult(
          finalUrl: target,
          cookies: cookies,
        );
      }

      if (status >= 200 && status < 300) {
        final html = response.data;
        if (html == null || html.trim().isEmpty) {
          throw DlcExplorerException(
            'Dashboard login returned an empty page (HTTP $status).',
          );
        }
        return DlcExplorerLoginResult(
          finalUrl: response.realUri,
          cookies: cookies,
          html: html,
        );
      }

      throw DlcExplorerException(
        'Dashboard login failed (HTTP $status).',
      );
    } on DioException catch (error) {
      throw DlcExplorerException(_messageForDioError(error, dashboardUrl));
    }
  }
}

class DlcExplorerException implements Exception {
  DlcExplorerException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _messageForDioError(DioException error, String dashboardUrl) {
  switch (error.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return 'Timed out connecting to DLC Explorer at $dashboardUrl.';
    case DioExceptionType.connectionError:
      return 'Cannot reach DLC Explorer at $dashboardUrl. '
          'Check DLC_EXPLORER_URL and network access to the dashboard.';
    default:
      break;
  }
  final status = error.response?.statusCode;
  if (status != null) {
    return 'Dashboard login failed (HTTP $status).';
  }
  return 'Dashboard login failed: ${error.message ?? error.type.name}';
}

List<WebViewCookie> _webViewCookiesFromResponse({
  required Response<dynamic> response,
  required Uri baseUri,
}) {
  final rawHeaders = response.headers.map['set-cookie'];
  if (rawHeaders == null || rawHeaders.isEmpty) return const [];

  final cookies = <WebViewCookie>[];
  for (final header in rawHeaders) {
    final parsed = _parseSetCookieHeader(header, baseUri);
    if (parsed != null) cookies.add(parsed);
  }
  return cookies;
}

WebViewCookie? _parseSetCookieHeader(String header, Uri baseUri) {
  final segments = header.split(';');
  if (segments.isEmpty) return null;

  final nameValue = segments.first.trim();
  final equalsIndex = nameValue.indexOf('=');
  if (equalsIndex <= 0) return null;

  final name = nameValue.substring(0, equalsIndex).trim();
  final value = nameValue.substring(equalsIndex + 1).trim();
  if (name.isEmpty) return null;

  var path = '/';
  String? domain;
  for (final segment in segments.skip(1)) {
    final part = segment.trim();
    final lower = part.toLowerCase();
    if (lower.startsWith('path=')) {
      path = part.substring(5).trim();
    } else if (lower.startsWith('domain=')) {
      domain = part.substring(7).trim();
    }
  }

  return WebViewCookie(
    name: name,
    value: value,
    domain: domain ?? baseUri.host,
    path: path.isEmpty ? '/' : path,
  );
}
