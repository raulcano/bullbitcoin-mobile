import 'dart:convert';

import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';

const _defaultExplorerBaseUrl = 'http://backend.coldpay.de:8300';

/// Resolves the DLC id to open in the user dashboard for [order].
String? dlcExplorerDlcIdForOrder(DlcOrderSummary order) {
  final direct = order.dlcId?.trim();
  if (direct != null && direct.isNotEmpty) return direct;

  final matched = order.matchedDlcId?.trim();
  if (matched != null && matched.isNotEmpty) return matched;

  return null;
}

/// Root URL for the DLC Explorer dashboard POST (trailing slash).
String dlcExplorerDashboardPostUrl(Environment environment) {
  final base = environment.isTestnet
      ? ApiServiceConstants.dlcExplorerTestBaseUrl
      : ApiServiceConstants.dlcExplorerBaseUrl;
  final trimmed = base.trim();
  if (trimmed.isEmpty) return '$_defaultExplorerBaseUrl/';
  return trimmed.endsWith('/') ? trimmed : '$trimmed/';
}

/// URL-encoded POST body for the dashboard login form.
///
/// Token is sent in the body only, never in the URL.
String dlcExplorerFormUrlEncodedBody({
  required String walletToken,
  required String dlcId,
}) {
  return [
    '${Uri.encodeQueryComponent('wallet_token')}=${Uri.encodeQueryComponent(walletToken)}',
    '${Uri.encodeQueryComponent('dlc_id')}=${Uri.encodeQueryComponent(dlcId)}',
  ].join('&');
}

/// HTML page that auto-submits a standards-compliant login form via POST.
///
/// Values are HTML-escaped for attribute context; the browser performs
/// `application/x-www-form-urlencoded` encoding on submit (not pre-encoded).
String dlcExplorerAutoSubmitHtml({
  required String dashboardUrl,
  required String walletToken,
  required String dlcId,
}) {
  final esc = const HtmlEscape(HtmlEscapeMode.attribute).convert;
  final action = esc(dashboardUrl);
  final token = esc(walletToken);
  final id = esc(dlcId);

  return '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>DLC Explorer</title>
</head>
<body>
<form id="dlc-explorer-login" method="post" action="$action">
<input type="hidden" name="wallet_token" value="$token">
<input type="hidden" name="dlc_id" value="$id">
<noscript><button type="submit">Open DLC Explorer</button></noscript>
</form>
<script>document.getElementById('dlc-explorer-login').submit();</script>
</body>
</html>''';
}
