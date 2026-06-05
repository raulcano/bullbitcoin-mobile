import 'dart:io';

import 'package:bb_mobile/features/dlc/data/dlc_explorer_client.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// Opens the ColdPay DLC Explorer dashboard after a form POST login.
class DlcExplorerScreen extends StatefulWidget {
  const DlcExplorerScreen({
    super.key,
    required this.dashboardUrl,
    required this.walletToken,
    required this.dlcId,
    DlcExplorerClient? client,
  }) : _client = client;

  final String dashboardUrl;
  final String walletToken;
  final String dlcId;
  final DlcExplorerClient? _client;

  @override
  State<DlcExplorerScreen> createState() => _DlcExplorerScreenState();
}

class _DlcExplorerScreenState extends State<DlcExplorerScreen> {
  final _cookieManager = WebViewCookieManager();
  WebViewController? _controller;
  var _pageLoading = false;
  var _bootstrapping = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _bootstrapping = true;
      _error = null;
      _controller = null;
    });

    try {
      final client = widget._client ?? DlcExplorerClient();
      final login = await client.login(
        dashboardUrl: widget.dashboardUrl,
        walletToken: widget.walletToken,
        dlcId: widget.dlcId,
      );

      for (final cookie in login.cookies) {
        await _cookieManager.setCookie(cookie);
      }

      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (_) {
              if (!mounted) return;
              setState(() => _pageLoading = true);
            },
            onPageFinished: (_) {
              if (!mounted) return;
              setState(() => _pageLoading = false);
            },
            onWebResourceError: (error) {
              if (!mounted) return;
              setState(() {
                _pageLoading = false;
                _error = error.description;
              });
            },
          ),
        );

      if (Platform.isAndroid) {
        AndroidWebViewController.enableDebugging(false);
        final platformController = controller.platform;
        if (platformController is AndroidWebViewController) {
          platformController.setMediaPlaybackRequiresUserGesture(false);
        }
      } else if (Platform.isIOS) {
        final platformController = controller.platform;
        if (platformController is WebKitWebViewController) {
          platformController.setAllowsBackForwardNavigationGestures(true);
        }
      }

      if (login.html != null) {
        await controller.loadHtmlString(
          login.html!,
          baseUrl: login.finalUrl.toString(),
        );
      } else {
        await controller.loadRequest(login.finalUrl);
      }

      if (!mounted) return;
      setState(() {
        _controller = controller;
        _bootstrapping = false;
        _pageLoading = true;
      });
    } on DlcExplorerException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _bootstrapping = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not open DLC Explorer: $error';
        _bootstrapping = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DLC Explorer'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_bootstrapping) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Could not open DLC Explorer.',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _bootstrap,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final controller = _controller;
    if (controller == null) {
      return const SizedBox.shrink();
    }

    return Stack(
      children: [
        WebViewWidget(controller: controller),
        if (_pageLoading) const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}
