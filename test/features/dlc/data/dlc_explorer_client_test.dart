import 'package:bb_mobile/features/dlc/data/dlc_explorer_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  group('DlcExplorerClient.login', () {
    test('returns redirect target and session cookie', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.method, 'POST');
            expect(options.contentType, Headers.formUrlEncodedContentType);
            expect(options.data, {
              'wallet_token': 'token-abc',
              'dlc_id': 'dlc-1',
            });
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 302,
                headers: Headers.fromMap({
                  'location': ['/dashboard'],
                  'set-cookie': [
                    'session=abc123; Path=/; HttpOnly',
                  ],
                }),
              ),
            );
          },
        ),
      );

      final result = await DlcExplorerClient(dio: dio).login(
        dashboardUrl: 'http://backend.coldpay.de:8300/',
        walletToken: 'token-abc',
        dlcId: 'dlc-1',
      );

      expect(result.finalUrl, Uri.parse('http://backend.coldpay.de:8300/dashboard'));
      expect(result.html, isNull);
      expect(result.cookies, [
        isA<WebViewCookie>()
            .having((c) => c.name, 'name', 'session')
            .having((c) => c.value, 'value', 'abc123')
            .having((c) => c.domain, 'domain', 'backend.coldpay.de'),
      ]);
    });

    test('returns inline HTML for 200 response', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<html><body>Dashboard</body></html>',
              ),
            );
          },
        ),
      );

      final result = await DlcExplorerClient(dio: dio).login(
        dashboardUrl: 'http://backend.coldpay.de:8300/',
        walletToken: 'token-abc',
        dlcId: 'dlc-1',
      );

      expect(result.html, contains('Dashboard'));
      expect(result.finalUrl, Uri.parse('http://backend.coldpay.de:8300/'));
    });
  });
}
