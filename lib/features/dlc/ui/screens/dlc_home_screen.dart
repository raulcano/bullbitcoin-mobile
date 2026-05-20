import 'dart:async';

import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_instrument_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_in_flight.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_option_payout_simulation.dart';
import 'package:bb_mobile/features/dlc/data/dlc_api_datasource.dart';
import 'package:bb_mobile/features/dlc/data/dlc_repository.dart';
import 'package:bb_mobile/features/dlc/presentation/dlc_cubit.dart';
import 'package:bb_mobile/features/dlc/presentation/dlc_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:bb_mobile/features/dlc/ui/widgets/dlc_action_loading_overlay.dart';
import 'package:bb_mobile/features/dlc/ui/widgets/dlc_option_payout_chart.dart';
import 'package:bb_mobile/locator.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

class DlcHomeScreen extends StatefulWidget {
  const DlcHomeScreen({super.key});

  @override
  State<DlcHomeScreen> createState() => _DlcHomeScreenState();
}

class _DlcHomeScreenState extends State<DlcHomeScreen> {
  bool _simulateLoading = false;
  final _quantityController = TextEditingController(text: '0.01');
  final _premiumController = TextEditingController(
    text: ApiServiceConstants.dlcDefaultPremiumPerContractSatoshis.toString(),
  );

  void _applyDepthRowToCreateOrder({
    required double strikePrice,
    required bool isAskRow,
    required Map<String, dynamic> row,
  }) {
    final qtyRaw = row['quantity'] ?? row['amount'];
    final qty = qtyRaw is num
        ? qtyRaw.toDouble()
        : double.tryParse(qtyRaw?.toString().trim() ?? '');
    if (qty == null || qty <= 0) return;

    final premSats = dlcOrderbookPremiumPerFullContractSatoshis(row);

    final cubit = context.read<DlcCubit>();
    cubit.applyCreateOrderFromOrderbookDepth(
      strikePrice: strikePrice,
      isAskRow: isAskRow,
      quantity: qty,
      premiumPerContractSats: premSats,
    );

    final qtyText = _formatDecimalInput(qty);
    _quantityController.text = qtyText;

    if (premSats != null) {
      _premiumController.text = premSats.toString();
    }
  }

  void _showCreateOrderMatchingInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Order matching'),
        content: Text(
          'Matching is exact quantity only (no partial fills). '
          '“Filled” on an order is a market state, not guaranteed economic settlement.',
          style: Theme.of(ctx).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showOwnOrderbookOrdersInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your orders on the book'),
        content: Text(
          'Rows that match your wallet’s open orders are shown with a dashed '
          'underline so you can tell them apart from other participants.',
          style: Theme.of(ctx).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Loads coordinator catalog only; wallet session starts on Activate.
      context.read<DlcCubit>().load();
    });
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _premiumController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DlcCubit, DlcState>(
      builder: (context, state) {
        final filteredInstruments = state.instruments
            .where((i) => dlcInstrumentMatchesOptionType(i, state.optionType))
            .toList();
        final selectedForOrderbook = dlcInstrumentById(
          filteredInstruments,
          state.selectedInstrumentId,
        );
        final openOrders = state.orders
            .where(orderShowsInOpenSection)
            .toList(growable: false);
        final liveOrders = state.orders
            .where(orderShowsInLiveSection)
            .toList(growable: false);
        final closedOrders = state.orders
            .where(isDlcClosedOrder)
            .toList(growable: false);
        final tradingBlocked = _tradingBlocked(state);

        final showActionOverlay = state.actionInProgress ||
            state.orderbookRefreshing ||
            _simulateLoading;

        return Scaffold(
          body: DlcActionLoadingOverlay(
            visible: showActionOverlay,
            child: SafeArea(
              child: Column(
                children: [
                _DlcHomeTopNav(
                  selectedIndex: state.selectedTabIndex,
                  loading: state.loading || _simulateLoading,
                  onSelect: (idx) {
                    context.read<DlcCubit>().setTab(idx);
                    if (idx == 1) {
                      unawaited(context.read<DlcCubit>().refreshOrderbookTab());
                    }
                  },
                ),
                const _DlcColdPayAttribution(),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: context.read<DlcCubit>().refreshCurrentTab,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                      children: [
                        if (state.errorMessage != null) ...[
                          const SizedBox(height: 12),
                          _DlcTransientMessageBanner(
                            message: state.errorMessage!,
                            icon: Icons.error_outline,
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.errorContainer,
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                            onDismiss: context.read<DlcCubit>().clearTransientMessages,
                          ),
                        ],
                        if (state.infoMessage != null) ...[
                          const SizedBox(height: 12),
                          _DlcTransientMessageBanner(
                            message: state.infoMessage!,
                            icon: Icons.info_outline,
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primaryContainer,
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onPrimaryContainer,
                            onDismiss: context.read<DlcCubit>().clearTransientMessages,
                          ),
                        ],
                        const SizedBox(height: 8),
                        if (state.selectedTabIndex == 0) ...[
                          _OverviewPanel(state: state),
                        ] else if (state.selectedTabIndex == 1) ...[
                          _OrderbookInstrumentCard(
                            state: state,
                            selectedInstrument: selectedForOrderbook,
                            loading: state.loading || state.orderbookRefreshing,
                            onDepthRowTap: _applyDepthRowToCreateOrder,
                            onOwnOrdersInfoTap: () =>
                                _showOwnOrderbookOrdersInfo(context),
                          ),
                          if (filteredInstruments.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                'No instruments for this option type. Pull to refresh.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          const SizedBox(height: 16),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.add_chart_outlined,
                                        size: 18,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Create order',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      const Spacer(),
                                      IconButton(
                                        icon: const Icon(Icons.info_outline),
                                        tooltip: 'Matching details',
                                        visualDensity: VisualDensity.compact,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                          minWidth: 36,
                                          minHeight: 36,
                                        ),
                                        onPressed: () =>
                                            _showCreateOrderMatchingInfo(
                                              context,
                                            ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  SegmentedButton<DlcOrderSide>(
                                    segments: const [
                                      ButtonSegment(
                                        value: DlcOrderSide.buy,
                                        label: Text('Buy'),
                                      ),
                                      ButtonSegment(
                                        value: DlcOrderSide.sell,
                                        label: Text('Sell'),
                                      ),
                                    ],
                                    selected: {state.side},
                                    onSelectionChanged: state.loading
                                        ? null
                                        : (selection) => context
                                              .read<DlcCubit>()
                                              .setSide(selection.first),
                                  ),
                                  const SizedBox(height: 8),
                                  _CreateOrderStrikeField(state: state),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: _quantityController,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: const InputDecoration(
                                      labelText: 'Number of contracts',
                                      helperText:
                                          '1 contract = 1 BTC. Minimum 0.01 contracts.',
                                    ),
                                    onChanged: context
                                        .read<DlcCubit>()
                                        .setQuantity,
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: _premiumController,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: false,
                                        ),
                                    decoration: InputDecoration(
                                      labelText:
                                          'Premium per contract (option price)',
                                      helperText:
                                          'Satoshis per contract (whole number).',
                                    ),
                                    onChanged: context
                                        .read<DlcCubit>()
                                        .setPrice,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Estimated total premium: ${_formatEstimatedPremiumSats(state.price * state.quantity)}',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton.icon(
                                    onPressed: state.auth == null || tradingBlocked
                                        ? null
                                        : () => context
                                              .read<DlcCubit>()
                                              .createOrder(),
                                    icon: const Icon(Icons.add_chart),
                                    label: const Text('Create'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ] else if (state.selectedTabIndex == 2) ...[
                          _OrderGroupSection(
                            title: 'Open orders',
                            subtitle: 'Waiting for a match',
                            orders: openOrders,
                            processingOrder: state.processingOrder,
                            showCancel: true,
                          ),
                          const SizedBox(height: 12),
                          _OrderGroupSection(
                            title: 'Live orders',
                            subtitle:
                                'Pending accept, filled, or settlement in progress',
                            orders: liveOrders,
                            processingOrder: state.processingOrder,
                          ),
                          const SizedBox(height: 12),
                          _OrderGroupSection(
                            title: 'Closed / settled',
                            subtitle: 'Completed DLCs and finalized orders',
                            orders: closedOrders,
                            processingOrder: state.processingOrder,
                            leadingIcon: Icons.task_alt_outlined,
                          ),
                        ] else ...[
                          _SimulateTabPanel(
                            state: state,
                            onLoadingChanged: (loading) {
                              if (_simulateLoading == loading) return;
                              setState(() => _simulateLoading = loading);
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          ),
        );
      },
    );
  }
}

class _DlcTransientMessageBanner extends StatelessWidget {
  const _DlcTransientMessageBanner({
    required this.message,
    required this.icon,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onDismiss,
  });

  final String message;
  final IconData icon;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: foregroundColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: foregroundColor),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, color: foregroundColor, size: 20),
            tooltip: 'Dismiss',
            onPressed: onDismiss,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// Bitcoin brand orange for ColdPay attribution period.
const _dlcBitcoinOrange = Color(0xFFF7931A);
const _coldPayWebsite = 'https://www.coldpay.me';

class _DlcColdPayAttribution extends StatelessWidget {
  const _DlcColdPayAttribution();

  Future<void> _openColdPayWebsite() async {
    final uri = Uri.parse(_coldPayWebsite);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final baseSize = baseStyle?.fontSize ?? 12;
    final italicStyle = baseStyle?.copyWith(fontStyle: FontStyle.italic);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: InkWell(
          onTap: _openColdPayWebsite,
          borderRadius: BorderRadius.circular(4),
          child: RichText(
              textAlign: TextAlign.right,
              text: TextSpan(
                children: [
                  TextSpan(text: 'Powered by ', style: italicStyle),
                  TextSpan(text: 'ColdPay', style: baseStyle),
                  TextSpan(
                    text: '.',
                    style: baseStyle?.copyWith(
                      fontSize: baseSize * 2.6,
                      color: _dlcBitcoinOrange,
                      fontWeight: FontWeight.w600,
                      height: 0.75,
                    ),
                  ),
                ],
              ),
            ),
        ),
      ),
    );
  }
}

/// Pill-style tab strip with comfortable tap targets (replaces flat segmented control).
class _DlcHomeTopNav extends StatelessWidget {
  const _DlcHomeTopNav({
    required this.selectedIndex,
    required this.loading,
    required this.onSelect,
  });

  final int selectedIndex;
  final bool loading;
  final void Function(int index) onSelect;

  static const List<_DlcNavSpec> _tabs = [
    _DlcNavSpec(0, Icons.dashboard_outlined, 'Overview'),
    _DlcNavSpec(1, Icons.menu_book_outlined, 'Orderbook'),
    _DlcNavSpec(2, Icons.list_alt_outlined, 'My Orders'),
    _DlcNavSpec(3, Icons.calculate_outlined, 'Simulate'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Row(
            children: [
              for (final tab in _tabs)
                Expanded(
                  child: _DlcHomeNavItem(
                    icon: tab.icon,
                    label: tab.label,
                    selected: selectedIndex == tab.index,
                    enabled: !loading,
                    onTap: () => onSelect(tab.index),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DlcNavSpec {
  const _DlcNavSpec(this.index, this.icon, this.label);

  final int index;
  final IconData icon;
  final String label;
}

class _DlcHomeNavItem extends StatelessWidget {
  const _DlcHomeNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    final radius = BorderRadius.circular(13);

    return AnimatedOpacity(
      opacity: enabled ? 1 : 0.42,
      duration: const Duration(milliseconds: 160),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: radius,
          splashColor: scheme.primary.withValues(alpha: 0.12),
          highlightColor: scheme.primary.withValues(alpha: 0.06),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 4),
            decoration: BoxDecoration(
              color: selected ? scheme.surface : Colors.transparent,
              borderRadius: radius,
              border: Border.all(
                color: selected
                    ? scheme.outlineVariant.withValues(alpha: 0.55)
                    : Colors.transparent,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 23,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 13,
                    height: 1.05,
                    letterSpacing: 0.15,
                    color:
                        selected ? scheme.onSurface : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SimulateTabPanel extends StatefulWidget {
  const _SimulateTabPanel({
    required this.state,
    required this.onLoadingChanged,
  });

  final DlcState state;
  final void Function(bool loading) onLoadingChanged;

  @override
  State<_SimulateTabPanel> createState() => _SimulateTabPanelState();
}

const _kSimulateStrikeFallbackUsd = 70000;

int _defaultSimulateStrikeUsd(DlcState state) =>
    state.btcUsdSpotPrice?.round() ?? _kSimulateStrikeFallbackUsd;

class _SimulateTabPanelState extends State<_SimulateTabPanel> {
  late final TextEditingController _contractsController;
  late final TextEditingController _strikeController;
  late final TextEditingController _premiumController;
  late final TextEditingController _expiryBtcUsdController;
  late final TextEditingController _networkFeeController;
  DlcOrderSide _role = DlcOrderSide.buy;
  DlcOptionType _optionKind = DlcOptionType.call;
  /// Coordinator `role`: `maker` or `taker`.
  String _orderRole = 'maker';
  bool _loading = false;
  String? _error;
  DlcOptionPayoutSimulationResult? _result;
  int _chartStrikeUsd = 0;
  int _chartOutcomeUsd = 0;
  final _payoutChartKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final s = widget.state;
    _contractsController = TextEditingController(text: '1');
    _strikeController = TextEditingController(
      text: _defaultSimulateStrikeUsd(s).toString(),
    );
    _premiumController = TextEditingController(
      text: s.price.round().toString(),
    );
    final spot = s.btcUsdSpotPrice;
    _expiryBtcUsdController = TextEditingController(
      text: spot != null ? spot.round().toString() : '',
    );
    _networkFeeController = TextEditingController(text: '0');
    if (s.btcUsdSpotPrice == null) {
      unawaited(_refreshSimulateStrikeFromSpotIfNeeded());
    }
  }

  Future<void> _refreshSimulateStrikeFromSpotIfNeeded() async {
    try {
      final spot = await locator<DlcRepository>().getBtcUsdSpotPrice();
      if (!mounted) return;
      final fallbackText = _kSimulateStrikeFallbackUsd.toString();
      if (_strikeController.text.trim() == fallbackText) {
        setState(() {
          _strikeController.text = spot.round().toString();
        });
      }
    } catch (_) {
      // Keep [_kSimulateStrikeFallbackUsd] when ticker URL is unavailable.
    }
  }

  @override
  void didUpdateWidget(covariant _SimulateTabPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final spot = widget.state.btcUsdSpotPrice;
    if (spot == null || spot == oldWidget.state.btcUsdSpotPrice) return;
    final fallbackText = _kSimulateStrikeFallbackUsd.toString();
    if (_strikeController.text.trim() == fallbackText) {
      _strikeController.text = spot.round().toString();
    }
  }

  @override
  void dispose() {
    _contractsController.dispose();
    _strikeController.dispose();
    _premiumController.dispose();
    _expiryBtcUsdController.dispose();
    _networkFeeController.dispose();
    super.dispose();
  }

  Future<void> _runSimulation() async {
    FocusScope.of(context).unfocus();
    final messenger = ScaffoldMessenger.maybeOf(context);

    final qtyRaw = _contractsController.text.trim().replaceAll(',', '');
    final qty = double.tryParse(qtyRaw);
    if (qty == null || qty <= 0) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Enter a valid number of contracts (> 0).')),
      );
      return;
    }

    final strikeParsed =
        double.tryParse(_strikeController.text.trim().replaceAll(',', ''));
    if (strikeParsed == null || strikeParsed < 1) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Strike must be at least 1 (whole BTC/USD units).'),
        ),
      );
      return;
    }
    final strikeInt = strikeParsed.round();
    if (strikeInt < 1) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Strike must be at least 1.')),
      );
      return;
    }

    final premium = int.tryParse(_premiumController.text.trim());
    if (premium == null || premium < 0) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Premium per contract must be a whole sats amount ≥ 0.'),
        ),
      );
      return;
    }

    final outcome =
        int.tryParse(_expiryBtcUsdController.text.trim().replaceAll(',', ''));
    if (outcome == null || outcome < 0) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Expiry BTC/USD must be a whole number ≥ 0.'),
        ),
      );
      return;
    }

    final networkFee =
        int.tryParse(_networkFeeController.text.trim()) ?? 0;
    if (networkFee < 0) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Network fee estimate cannot be negative.')),
      );
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    widget.onLoadingChanged(true);

    final req = DlcOptionPayoutSimulationRequest(
      side: _role == DlcOrderSide.buy ? 'buy' : 'sell',
      role: _orderRole,
      optionRight: _optionKind == DlcOptionType.call ? 'C' : 'P',
      numContracts: qty,
      strike: strikeInt,
      premiumPerContractSats: premium,
      outcomePrice: outcome,
      premiumPaidUpfront: true,
      networkFeeSats: networkFee,
      numDigits: 8,
    );

    try {
      final result =
          await locator<DlcRepository>().simulateOptionPayout(req);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _result = result;
        _chartStrikeUsd = strikeInt;
        _chartOutcomeUsd = outcome;
      });
      widget.onLoadingChanged(false);
      _scrollToPayoutChart();
    } on DlcApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _result = null;
        _error = e.message;
      });
      widget.onLoadingChanged(false);
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      setState(() {
        _loading = false;
        _result = null;
        _error = msg;
      });
      widget.onLoadingChanged(false);
      messenger?.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void _scrollToPayoutChart() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _payoutChartKey.currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.08,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _showSimulatePayoutInfoDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Simulate payout'),
        content: SingleChildScrollView(
          child: Text(
            'Use this tool to explore what payout you could receive for the '
            'role, contracts, strike, premium, and BTC/USD outcome you enter.\n\n'
            'Tapping Simulate only runs a calculation against the coordinator — '
            'no funds move, no order is placed, and nothing is signed on-chain. '
            'It is a hypothetical exercise to help you understand settlement '
            'before you trade.',
            style: Theme.of(ctx).textTheme.bodyMedium,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showRoundingDeltaInfoDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rounding delta'),
        content: SingleChildScrollView(
          child: Text(
            'The coordinator expresses DLC payouts as a stepped curve: '
            'oracle outcomes are grouped into intervals, and each interval has '
            'a fixed wallet payout (see the chart).\n\n'
            'Rounding delta is the gap between that stepped (rounded) payout '
            'and the smooth theoretical payout at the same BTC/USD price — '
            'in other words, how much interval rounding moves your settlement '
            'versus the ideal curve.\n\n'
            'Positive means the rounded payout is higher than the canonical '
            'value at this outcome; negative means it is lower.',
            style: Theme.of(ctx).textTheme.bodyMedium,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _usdField({
    required TextEditingController controller,
    required double width,
    required String hintText,
    bool allowDecimal = true,
  }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.numberWithOptions(decimal: allowDecimal),
        inputFormatters: allowDecimal
            ? null
            : [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          isDense: true,
          hintText: hintText,
          suffixText: 'USD',
          suffixStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 10,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Widget _contractsField() {
    return SizedBox(
      width: 88,
      child: TextField(
        controller: _contractsController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'qty',
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 10,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Widget _premiumField() {
    return SizedBox(
      width: 130,
      child: TextField(
        controller: _premiumController,
        keyboardType: const TextInputType.numberWithOptions(decimal: false),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'premium',
          suffixText: 'sats',
          suffixStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 10,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final body = theme.textTheme.bodyMedium;

    final segmentStyle = SegmentedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: const Size(0, 34),
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      foregroundColor: theme.colorScheme.onSurface,
      selectedBackgroundColor: theme.colorScheme.surfaceContainerLow,
      selectedForegroundColor: theme.colorScheme.onSurface,
      side: BorderSide(color: theme.colorScheme.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.calculate_outlined,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Simulate payout',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.info_outline),
                      tooltip: 'About simulate payout',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      onPressed: () => _showSimulatePayoutInfoDialog(context),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 12,
                  children: [
                    Text('I am the', style: body),
                    SegmentedButton<DlcOrderSide>(
                      showSelectedIcon: false,
                      style: segmentStyle,
                      segments: const [
                        ButtonSegment(
                          value: DlcOrderSide.buy,
                          label: Text('buyer'),
                        ),
                        ButtonSegment(
                          value: DlcOrderSide.sell,
                          label: Text('seller'),
                        ),
                      ],
                      selected: {_role},
                      onSelectionChanged: _loading
                          ? null
                          : (next) =>
                              setState(() => _role = next.first),
                    ),
                    Text('of', style: body),
                    _contractsField(),
                    Text('contracts of', style: body),
                    SegmentedButton<DlcOptionType>(
                      showSelectedIcon: false,
                      style: segmentStyle,
                      segments: const [
                        ButtonSegment(
                          value: DlcOptionType.put,
                          label: Text('PUT'),
                        ),
                        ButtonSegment(
                          value: DlcOptionType.call,
                          label: Text('CALL'),
                        ),
                      ],
                      selected: {_optionKind},
                      onSelectionChanged: _loading
                          ? null
                          : (next) =>
                              setState(() => _optionKind = next.first),
                    ),
                    Text('Bitcoin option.', style: body),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 12,
                  children: [
                    Text('My order role:', style: body),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      style: segmentStyle,
                      segments: const [
                        ButtonSegment(
                          value: 'maker',
                          label: Text('Maker'),
                        ),
                        ButtonSegment(
                          value: 'taker',
                          label: Text('Taker'),
                        ),
                      ],
                      selected: {_orderRole},
                      onSelectionChanged: _loading
                          ? null
                          : (next) =>
                              setState(() => _orderRole = next.first),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 12,
                  children: [
                    Text('The strike price is set at', style: body),
                    _usdField(
                      controller: _strikeController,
                      width: 112,
                      hintText: 'strike',
                    ),
                    Text('and the premium per contract is', style: body),
                    _premiumField(),
                    Text('.', style: body),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 12,
                  children: [
                    Text(
                      'Check my profit or loss if the Bitcoin price at '
                      'expiry is',
                      style: body,
                    ),
                    _usdField(
                      controller: _expiryBtcUsdController,
                      width: 120,
                      hintText: 'BTC/USD',
                      allowDecimal: false,
                    ),
                    Text('.', style: body),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Estimated network fee you pay (on-chain)',
                  style: subtle,
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _networkFeeController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: false),
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: 'Network fees',
                      suffixText: 'sats',
                      suffixStyle:
                          theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _loading ? null : _runSimulation,
                    icon: const Icon(Icons.play_arrow_outlined),
                    label: const Text('SIMULATE'),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_result != null) ...[
          const SizedBox(height: 12),
          Card(
            key: _payoutChartKey,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.show_chart_outlined,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _simulatePayoutCurveTitle(
                            role: _role,
                            optionKind: _optionKind,
                          ),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DlcOptionPayoutChart(
                    result: _result!,
                    strikeUsd: _chartStrikeUsd,
                    outcomeUsd: _chartOutcomeUsd,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.receipt_long_outlined,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Simulation results',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SimulateMetricRow(
                    label: 'PnL (rounded)',
                    value: _formatSimSatsSigned(_result!.roundedPnlSats),
                    emphasize: true,
                    valueColor: _simulationPnlValueColor(
                      context,
                      _result!.roundedPnlSats,
                    ),
                  ),
                  _SimulateMetricRow(
                    label: 'PnL (no fees incl.)',
                    value: _formatSimSatsSigned(
                      _result!.roundedPnlSats +
                          _result!.networkFeeSats +
                          _result!.walletFeeSats,
                    ),
                    valueColor: _simulationPnlValueColor(
                      context,
                      _result!.roundedPnlSats +
                          _result!.networkFeeSats +
                          _result!.walletFeeSats,
                    ),
                  ),
                  _SimulateMetricRow(
                    label: 'Posted collateral',
                    value: _formatSimSatsUnsigned(
                      _result!.walletPostedCollateralSats,
                    ),
                  ),
                  _SimulateMetricRow(
                    label: 'Premium paid (upfront)',
                    value: _formatSimSatsUnsigned(
                      _result!.premiumPaidUpfrontSats,
                    ),
                  ),
                  _SimulateMetricRow(
                    label: 'Premium received (upfront)',
                    value: _formatSimSatsUnsigned(
                      _result!.premiumReceivedUpfrontSats,
                    ),
                  ),
                  _SimulateMetricRow(
                    label: 'Premium embedded in DLC',
                    value: _formatSimSatsUnsigned(
                      _result!.premiumEmbeddedInDlcSats,
                    ),
                  ),
                  _SimulateMetricRow(
                    label: 'Rounded settlement payout',
                    value: _formatSimSatsUnsigned(
                      _result!.walletRoundedSettlementPayoutSats,
                    ),
                  ),
                  _SimulateMetricRow(
                    label: 'Canonical payout',
                    value: _formatSimSatsUnsigned(
                      _result!.walletCanonicalPayoutSats,
                    ),
                  ),
                  _SimulateMetricRow(
                    label: 'Network fees',
                    value: _formatSimSatsUnsigned(_result!.networkFeeSats),
                  ),
                  _SimulateMetricRow(
                    label: 'Wallet/service fees',
                    value: _formatSimSatsUnsigned(_result!.walletFeeSats),
                  ),
                  _SimulateMetricRow(
                    label: 'Total fees',
                    value: _formatSimSatsUnsigned(_result!.totalFeeSats),
                  ),
                  _SimulateMetricRow(
                    label: 'Rounding delta',
                    value: _formatSimSatsSigned(_result!.roundingDeltaSats),
                    onLabelInfoTap: () =>
                        _showRoundingDeltaInfoDialog(context),
                    labelInfoTooltip: 'About rounding delta',
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

String _simulatePayoutCurveTitle({
  required DlcOrderSide role,
  required DlcOptionType optionKind,
}) {
  final direction = role == DlcOrderSide.buy ? 'LONG' : 'SHORT';
  final right = optionKind == DlcOptionType.call ? 'CALL' : 'PUT';
  return 'Payout for $direction $right';
}

String _formatSimSatsUnsigned(int sats) =>
    '${NumberFormat.decimalPattern().format(sats)} sats';

String _formatSimSatsSigned(int sats) {
  final fmt = NumberFormat.decimalPattern();
  if (sats == 0) return '${fmt.format(0)} sats';
  final sign = sats > 0 ? '+' : '';
  return '$sign${fmt.format(sats)} sats';
}

/// Dark green on light surfaces; slightly brighter green on dark for contrast.
Color _simulationPnlValueColor(BuildContext context, int pnlSats) {
  if (pnlSats < 0) return Theme.of(context).colorScheme.error;
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF81C784)
      : const Color(0xFF1B5E20);
}

class _SimulateMetricRow extends StatelessWidget {
  const _SimulateMetricRow({
    required this.label,
    required this.value,
    this.emphasize = false,
    this.valueColor,
    this.onLabelInfoTap,
    this.labelInfoTooltip,
  });

  final String label;
  final String value;
  final bool emphasize;
  final Color? valueColor;
  final VoidCallback? onLabelInfoTap;
  final String? labelInfoTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: emphasize ? FontWeight.w700 : FontWeight.w600,
      color: valueColor ??
          (emphasize
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: onLabelInfoTap == null
                ? Text(label, style: theme.textTheme.bodyMedium)
                : Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 2,
                    children: [
                      Text(label, style: theme.textTheme.bodyMedium),
                      IconButton(
                        icon: Icon(
                          Icons.info_outline,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        tooltip: labelInfoTooltip ?? 'More information',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        onPressed: onLabelInfoTap,
                      ),
                    ],
                  ),
          ),
          Text(
            value,
            style: valueStyle,
          ),
        ],
      ),
    );
  }
}

class _OverviewPanel extends StatelessWidget {
  const _OverviewPanel({required this.state});

  final DlcState state;

  @override
  Widget build(BuildContext context) {
    final total = (state.totalBalanceSat ?? 0).toDouble();
    final available = (state.availableBalanceSat ?? 0).toDouble();
    final openOrdersCount = dlcOpenOrdersCount(state.orders);
    final liveOrdersCount = dlcLiveOrdersCount(state.orders);
    final closedOrdersCount =
        state.orders.where(isDlcClosedOrder).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.coordinatorTradingHint != null) ...[
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Theme.of(context).colorScheme.error),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 20,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      state.coordinatorTradingHint!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      state.auth == null
                          ? Icons.account_balance_wallet_outlined
                          : Icons.verified_user_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      state.auth == null
                          ? 'Activate wallet'
                          : 'Wallet registered',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (state.auth == null) ...[
                  Text(
                    'Choose a Bitcoin wallet and activate it for DLC. '
                    'Balances, orders, and UTXO sync run after you tap Activate.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: state.selectedRegistrationWalletOriginId,
                    isExpanded: true,
                    items: state.availableWallets
                        .map(
                          (wallet) {
                            final registered = state.registeredWalletAuths.any(
                              (auth) =>
                                  auth.walletOriginId == wallet.walletOriginId,
                            );
                            final suffix =
                                registered ? 'registered' : 'not registered';
                            return DropdownMenuItem(
                              value: wallet.walletOriginId,
                              child: Text('${wallet.label} ($suffix)'),
                            );
                          },
                        )
                        .toList(),
                    onChanged: state.loading || state.actionInProgress
                        ? null
                        : (value) {
                            if (value == null) return;
                            context.read<DlcCubit>().setRegistrationWallet(
                              value,
                            );
                          },
                    decoration: const InputDecoration(
                      labelText: 'Bitcoin wallet for DLC',
                    ),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed:
                        state.loading ||
                            state.actionInProgress ||
                            state.selectedRegistrationWalletOriginId == null
                        ? null
                        : () => context.read<DlcCubit>().activateWalletForDlc(
                            state.selectedRegistrationWalletOriginId!,
                          ),
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('Activate'),
                  ),
                ] else ...[
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _openRegisteredWalletOverlay(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            state.auth!.walletLabel,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Tap to view details or switch active wallet',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        _OverviewSummaryCardsRow(
          walletPnlSats: state.walletPnlSats,
          openOrdersCount: openOrdersCount,
          liveOrdersCount: liveOrdersCount,
          closedOrdersCount: closedOrdersCount,
          walletRegistered: state.auth != null,
        ),
        const SizedBox(height: 8),
        _BarStatCard(
          title: 'Balance split',
          subtitle: state.auth == null
              ? null
              : 'Coordinator-visible balances. Sync wallet UTXOs to reconcile '
                  'after funding or settlement broadcasts.',
          leftLabel: 'Available',
          leftValue: state.availableBalanceSat ?? 0,
          rightLabel: 'Reserved',
          rightValue: state.reservedBalanceSat ?? 0,
          leftRatio: total <= 0 ? 0 : available / total,
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.shield_moon_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Risk',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'DLC options can lock collateral and depend on oracle outcomes. '
                  'Only extended public keys and signatures are sent to the coordinator; '
                  'seeds and private keys stay on this device.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Recent DLC events',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          'No dedicated events endpoint exposed by coordinator API yet.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (state.expiredWallets.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.schedule_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Expired DLC registrations',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...state.expiredWallets.map(
                    (item) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Wallet ID: ${item.walletId}\nXPUB: ${item.xpub}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _openRegisteredWalletOverlay(BuildContext context) async {
    final auth = state.auth;
    if (auth == null) return;
    final onChainWalletIds = state.availableWallets
        .map((wallet) => wallet.walletOriginId)
        .toSet();
    final walletOptionsById = <String, DlcWalletOption>{
      for (final wallet in state.availableWallets)
        wallet.walletOriginId: wallet,
      for (final registered in state.registeredWalletAuths)
        if (onChainWalletIds.contains(registered.walletOriginId))
          registered.walletOriginId: DlcWalletOption(
            walletOriginId: registered.walletOriginId,
            label: registered.walletLabel,
            xpub: registered.walletXpub,
          ),
    };
    final walletOptions = walletOptionsById.values.toList();
    String draftOriginId = auth.walletOriginId;
    if (!walletOptionsById.containsKey(draftOriginId) &&
        walletOptions.isNotEmpty) {
      draftOriginId = walletOptions.first.walletOriginId;
    }
    final changed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Registered wallet'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Label: ${auth.walletLabel}'),
                  if (auth.expiresAt != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Expires: ${DateFormat.yMMMd().add_jm().format(auth.expiresAt!.toLocal())}',
                    ),
                  ],
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: draftOriginId,
                    isExpanded: true,
                    items: walletOptions.map((item) {
                      final registered = state.registeredWalletAuths.any(
                        (auth) => auth.walletOriginId == item.walletOriginId,
                      );
                      final suffix = registered
                          ? 'registered'
                          : 'not registered';
                      return DropdownMenuItem(
                        value: item.walletOriginId,
                        child: Text('${item.label} ($suffix)'),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => draftOriginId = value);
                    },
                    decoration: const InputDecoration(
                      labelText: 'Activate on-chain Bitcoin wallet for DLC',
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Close'),
                ),
                FilledButton(
                  onPressed: walletOptions.isEmpty
                      ? null
                      : () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Activate'),
                ),
              ],
            );
          },
        );
      },
    );
    if (changed == true && draftOriginId != auth.walletOriginId) {
      // ignore: use_build_context_synchronously
      await context.read<DlcCubit>().activateWalletForDlc(draftOriginId);
    }
  }
}

class _OverviewSummaryCardsRow extends StatelessWidget {
  const _OverviewSummaryCardsRow({
    required this.walletPnlSats,
    required this.openOrdersCount,
    required this.liveOrdersCount,
    required this.closedOrdersCount,
    required this.walletRegistered,
  });

  final int? walletPnlSats;
  final int openOrdersCount;
  final int liveOrdersCount;
  final int closedOrdersCount;
  final bool walletRegistered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pnlValue = walletRegistered && walletPnlSats != null
        ? dlcFormatGroupedSatoshis(walletPnlSats!.abs())
        : '—';
    final pnlPrefix = walletPnlSats != null && walletPnlSats! > 0 ? '+' : '';
    final pnlColor = walletRegistered && walletPnlSats != null
        ? _simulationPnlValueColor(context, walletPnlSats!)
        : theme.colorScheme.onSurfaceVariant;

    return Row(
      children: [
        Expanded(
          child: _OverviewSquareStatCard(
            label: 'Wallet PnL',
            value: walletRegistered && walletPnlSats != null
                ? '$pnlPrefix$pnlValue'
                : pnlValue,
            valueSuffix: walletRegistered && walletPnlSats != null ? 'sats' : null,
            valueColor: pnlColor,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _OverviewOrdersStatCard(
            openOrdersCount: openOrdersCount,
            liveOrdersCount: liveOrdersCount,
            closedOrdersCount: closedOrdersCount,
            walletRegistered: walletRegistered,
          ),
        ),
      ],
    );
  }
}

class _OverviewOrdersStatCard extends StatelessWidget {
  const _OverviewOrdersStatCard({
    required this.openOrdersCount,
    required this.liveOrdersCount,
    required this.closedOrdersCount,
    required this.walletRegistered,
  });

  final int openOrdersCount;
  final int liveOrdersCount;
  final int closedOrdersCount;
  final bool walletRegistered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dash = '—';
    final countsLine = walletRegistered
        ? '$openOrdersCount / $liveOrdersCount / $closedOrdersCount'
        : '$dash / $dash / $dash';

    return AspectRatio(
      aspectRatio: 1,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Open / Live / Closed',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  countsLine,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.05,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OverviewSquareStatCard extends StatelessWidget {
  const _OverviewSquareStatCard({
    required this.label,
    required this.value,
    this.valueSuffix,
    this.valueColor,
  });

  final String label;
  final String value;
  final String? valueSuffix;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: 1,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  value,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.05,
                    color: valueColor,
                  ),
                ),
                if (valueSuffix != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    valueSuffix!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BarStatCard extends StatelessWidget {
  const _BarStatCard({
    required this.title,
    this.subtitle,
    required this.leftLabel,
    required this.leftValue,
    required this.rightLabel,
    required this.rightValue,
    required this.leftRatio,
  });

  final String title;
  final String? subtitle;
  final String leftLabel;
  final int leftValue;
  final String rightLabel;
  final int rightValue;
  final double leftRatio;

  @override
  Widget build(BuildContext context) {
    final ratio = leftRatio.clamp(0, 1).toDouble();
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 8),
            LinearProgressIndicator(value: ratio),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('$leftLabel: $leftValue'),
                Text('$rightLabel: $rightValue'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderGroupSection extends StatelessWidget {
  const _OrderGroupSection({
    required this.title,
    required this.subtitle,
    required this.orders,
    required this.processingOrder,
    this.leadingIcon = Icons.pending_actions_outlined,
    this.showCancel = false,
  });

  final String title;
  final String subtitle;
  final List<DlcOrderSummary> orders;
  final bool processingOrder;
  final IconData leadingIcon;
  final bool showCancel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  leadingIcon,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            if (orders.isEmpty)
              const ListTile(
                dense: true,
                title: Text('No orders in this section'),
              )
            else
              ...orders.map(
                (order) => _CompactOrderEntry(
                  order: order,
                  processingOrder: processingOrder,
                  showCancel: showCancel,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CompactOrderEntry extends StatelessWidget {
  const _CompactOrderEntry({
    required this.order,
    required this.processingOrder,
    required this.showCancel,
  });

  final DlcOrderSummary order;
  final bool processingOrder;
  final bool showCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.instrumentId ?? '-',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      _formatOrderSide(order.side),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _orderSideHighlightColor(order.side) ??
                            colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Container(
                        width: 1,
                        height: 14,
                        color: colorScheme.outlineVariant,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Created: ${_formatOrderDate(order.createdAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (order.inFlightPhase != null) ...[
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'In progress',
                      onPressed: () =>
                          _showOrderInFlightDialog(context, order),
                      icon: Icon(
                        Icons.hourglass_top,
                        size: 20,
                        color: dlcOrderInFlightHourglassColor(
                          colorScheme,
                          order.inFlightPhase!,
                        ),
                      ),
                    ),
                    if (dlcOrderShowsInfoDuringInFlight(order.inFlightPhase!))
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Order info',
                        onPressed: () =>
                            _showOrderInfoDialog(context, order),
                        icon: const Icon(Icons.info_outline, size: 20),
                      ),
                  ] else
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Order info',
                      onPressed: () => _showOrderInfoDialog(context, order),
                      icon: const Icon(Icons.info_outline, size: 20),
                    ),
                  if (showCancel)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Cancel order',
                      onPressed: processingOrder
                          ? null
                          : () => _confirmCancelOrder(context, order),
                      icon: const Icon(Icons.close, size: 20),
                    ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> _confirmCancelOrder(
  BuildContext context,
  DlcOrderSummary order,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Cancel order?'),
      content: Text(
        'This will ask the coordinator to cancel order ${order.orderId}. '
        'If it has not already matched, it will be removed from the orderbook '
        'and will no longer be available for counterparties.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Keep order'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          icon: const Icon(Icons.close),
          label: const Text('Cancel order'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    await context.read<DlcCubit>().cancelOpenOrder(order.orderId);
  }
}

void _showOrderInFlightDialog(BuildContext context, DlcOrderSummary order) {
  final phase = order.inFlightPhase;
  if (phase == null) return;
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(dlcOrderInFlightDialogTitle(phase)),
      content: Text(
        dlcOrderInFlightDialogBody(phase: phase, order: order),
        style: Theme.of(dialogContext).textTheme.bodyMedium,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

void _showOrderInfoDialog(BuildContext context, DlcOrderSummary order) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Order info'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _InfoRow('Instrument', order.instrumentId ?? '-'),
            _InfoRow(
              'Seller collateral (sats)',
              dlcFormatOrderSellerCollateral(order),
            ),
            _InfoRow(
              'Contracts',
              order.quantity == null
                  ? '-'
                  : _formatDecimalInput(order.quantity!),
            ),
            _InfoRow(
              'Premium in this contract (sats)',
              dlcFormatOrderPremiumPerContract(order),
            ),
            _InfoRow('Side', _formatOrderSide(order.side)),
            _InfoRow('Role', formatDlcOrderRole(order)),
            _InfoRow('Order status', order.status),
            _InfoRow('DLC status', order.dlcStatus ?? '-'),
            _InfoRow('Partner fees', _formatOrderSats(order.partnerFeeSat)),
            _InfoRow('Network fees', _formatOrderSats(order.networkFeeSat)),
            _InfoRow('Order ID', order.orderId),
            _InfoRow('Created', _formatOrderDate(order.createdAt)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

bool _tradingBlocked(DlcState state) {
  final hint = state.coordinatorTradingHint?.toLowerCase() ?? '';
  return hint.contains('switch the app environment') ||
      hint.contains('does not report testnet') ||
      hint.contains('reports regtest while this app environment is mainnet');
}

String _instrumentDisplayId(String? rawId) => dlcInstrumentDisplayId(rawId);

String _formatUsdStrike(double strike) {
  final rounded = strike.round();
  final formatted = NumberFormat.decimalPattern().format(rounded);
  return '\$$formatted';
}

List<double> _strikeOptionsForState(DlcState state) {
  return dlcStrikesForOrderbook(
    templateInstrumentId: state.selectedInstrumentId,
    suggestedStrikePrices: state.suggestedStrikePrices,
  );
}

/// Strike selector for Create order (same strikes as the orderbook summary table).
class _CreateOrderStrikeField extends StatelessWidget {
  const _CreateOrderStrikeField({required this.state});

  final DlcState state;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DlcCubit>();
    final strikes = _strikeOptionsForState(state);
    final usesTemplate = dlcInstrumentUsesStrikeTemplate(
      state.selectedInstrumentId,
    );
    if (state.selectedInstrumentId == null) {
      return const SizedBox.shrink();
    }

    final selectedStrike =
        state.strikePrice != null && strikes.contains(state.strikePrice)
        ? state.strikePrice
        : null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: DropdownButtonFormField<double>(
            key: ValueKey<double?>(selectedStrike),
            initialValue: selectedStrike,
            isExpanded: true,
            items: strikes
                .map(
                  (strike) => DropdownMenuItem(
                    value: strike,
                    child: Text(_formatUsdStrike(strike)),
                  ),
                )
                .toList(),
            onChanged: state.loading || strikes.isEmpty
                ? null
                : (value) => cubit.setStrikePrice(value),
            decoration: InputDecoration(
              labelText: 'Strike',
              helperText: strikes.isEmpty
                  ? (state.btcUsdSpotPrice == null
                        ? 'Refresh to load strike suggestions.'
                        : 'Around spot ${_formatUsdStrike(state.btcUsdSpotPrice!)} in \$1,000 steps.')
                  : null,
              errorText: state.strikePriceError,
            ),
          ),
        ),
        if (usesTemplate) ...[
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'Refresh strikes',
            onPressed: state.loading
                ? null
                : () => cubit.refreshStrikePrices(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ],
    );
  }
}

String _formatDecimalInput(double value) {
  return value.toStringAsFixed(8).replaceFirst(RegExp(r'\.?0+$'), '');
}

String _formatBtcAmount(double value) {
  return value.toStringAsFixed(8).replaceFirst(RegExp(r'\.?0+$'), '');
}

String _formatOrderSats(double? sats) {
  if (sats == null) return '-';
  final btc = sats / 100000000;
  return '${_formatBtcAmount(btc)} BTC';
}

String _formatOrderDate(DateTime? date) {
  if (date == null) return '-';
  return DateFormat.yMMMd().add_Hm().format(date.toLocal());
}

String _formatOrderSide(String? side) {
  if (side == null || side.isEmpty) return '-';
  final normalized = side.toLowerCase();
  if (normalized == 'buy') return 'Buy';
  if (normalized == 'sell') return 'Sell';
  return side;
}

Color? _orderSideHighlightColor(String? side) {
  final normalized = side?.toLowerCase();
  if (normalized == 'buy') return const Color(0xFF1B5E20);
  if (normalized == 'sell') return const Color(0xFFB71C1C);
  return null;
}

String _formatEstimatedPremiumSats(double totalSats) {
  if (totalSats.isNaN || totalSats.isInfinite || totalSats < 0) return '-';
  return '${dlcFormatGroupedSatoshis(totalSats.round())} satoshis';
}

String _orderbookQuantityLabel(Map<String, dynamic> row) {
  final q = row['quantity'] ?? row['amount'];
  return q?.toString() ?? '-';
}

String _formatOrderbookPremiumCell(int? premiumSats) {
  if (premiumSats == null) return '-';
  return dlcFormatGroupedSatoshis(premiumSats);
}

Future<void> _showOrderbookPremiumInfoDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Ask and bid prices'),
      content: Text(
        'The price shown is the premium for one full contract. The final premium is the premium per contract multiplied by the number of contracts.'
        'One contract is equivalent to one Bitcoin (100,000,000 satoshis).',
        style: Theme.of(ctx).textTheme.bodyMedium,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// One row per strike: best ask (lowest) and best bid (highest) premium.
class _StrikeOrderbookSummaryTable extends StatelessWidget {
  const _StrikeOrderbookSummaryTable({
    required this.theme,
    required this.colorScheme,
    required this.snapshots,
    required this.onStrikeTap,
  });

  final ThemeData theme;
  final ColorScheme colorScheme;
  final List<DlcStrikeOrderbookSnapshot> snapshots;
  final void Function(DlcStrikeOrderbookSnapshot snapshot) onStrikeTap;

  @override
  Widget build(BuildContext context) {
    if (snapshots.isEmpty) {
      return Text(
        'No strikes available. Refresh to load strike suggestions.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }

    final borderColor = colorScheme.outlineVariant.withValues(alpha: 0.65);
    final headerStyle = theme.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w600,
    );
    final askColor = const Color(0xFFB71C1C);
    final bidColor = const Color(0xFF1B5E20);

    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1.1),
        1: FlexColumnWidth(1),
        2: FlexColumnWidth(1),
      },
      border: TableBorder(
        horizontalInside: BorderSide(color: borderColor),
        bottom: BorderSide(color: borderColor),
        verticalInside: BorderSide(color: borderColor),
      ),
      children: [
        TableRow(
          decoration: BoxDecoration(color: colorScheme.surfaceContainerHighest),
          children: [
            _summaryHeaderCell('Strike', headerStyle),
            _summaryHeaderCell(
              'Ask',
              headerStyle,
              color: askColor,
              onInfoTap: () => _showOrderbookPremiumInfoDialog(context),
            ),
            _summaryHeaderCell(
              'Bid',
              headerStyle,
              color: bidColor,
              onInfoTap: () => _showOrderbookPremiumInfoDialog(context),
            ),
          ],
        ),
        ...snapshots.map((snapshot) {
          return TableRow(
            children: [
              _summaryDataCell(
                onTap: () => onStrikeTap(snapshot),
                child: Text(
                  _formatUsdStrike(snapshot.strikePrice),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _summaryDataCell(
                onTap: () => onStrikeTap(snapshot),
                child: Text(
                  _formatOrderbookPremiumCell(snapshot.lowestAskPremiumSats),
                  style: theme.textTheme.bodyMedium?.copyWith(color: askColor),
                ),
              ),
              _summaryDataCell(
                onTap: () => onStrikeTap(snapshot),
                child: Text(
                  _formatOrderbookPremiumCell(snapshot.highestBidPremiumSats),
                  style: theme.textTheme.bodyMedium?.copyWith(color: bidColor),
                ),
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget _summaryHeaderCell(
    String label,
    TextStyle? style, {
    Color? color,
    VoidCallback? onInfoTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: style?.copyWith(color: color)),
          if (onInfoTap != null) ...[
            const SizedBox(width: 2),
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              tooltip: 'Premium per contract',
              icon: Icon(
                Icons.info_outline,
                size: 16,
                color: color ?? colorScheme.onSurfaceVariant,
              ),
              onPressed: onInfoTap,
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryDataCell({
    required VoidCallback onTap,
    required Widget child,
  }) {
    return TableCell(
      verticalAlignment: TableCellVerticalAlignment.middle,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: child,
        ),
      ),
    );
  }
}

Future<void> _showStrikeOrderbookDetailDialog({
  required BuildContext context,
  required DlcState state,
  required Map<String, dynamic>? selectedInstrument,
  required DlcStrikeOrderbookSnapshot snapshot,
  required void Function({
    required double strikePrice,
    required bool isAskRow,
    required Map<String, dynamic> row,
  })
  onDepthRowTap,
  required VoidCallback onOwnOrdersInfoTap,
}) {
  final templateId = state.selectedInstrumentId;
  if (templateId == null) return Future.value();

  final resolvedId = dlcInstrumentIdWithStrike(templateId, snapshot.strikePrice);
  final expiry = selectedInstrument != null
      ? dlcInstrumentExpiresAt(selectedInstrument)
      : null;
  final expiryText = expiry != null
      ? '${DateFormat.yMMMd().add_Hm().format(expiry.toUtc())} UTC'
      : null;
  final theme = Theme.of(context);
  final colorScheme = theme.colorScheme;

  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(dlcInstrumentDisplayId(resolvedId)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (expiryText != null)
                  Text(
                    'Maturity: $expiryText',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: 16),
                _OrderbookSideHeader(
                  label: 'Asks',
                  color: const Color(0xFFB71C1C),
                  showInfo: state.auth != null,
                  onInfoTap: onOwnOrdersInfoTap,
                ),
                const SizedBox(height: 6),
                _OrderbookDepthTable(
                  theme: theme,
                  colorScheme: colorScheme,
                  rows: snapshot.asks,
                  rowTextColor: const Color(0xFFB71C1C),
                  onRowTap: (row) {
                    Navigator.of(dialogContext).pop();
                    onDepthRowTap(
                      strikePrice: snapshot.strikePrice,
                      isAskRow: true,
                      row: row,
                    );
                  },
                  isOwnWalletRow: state.auth == null
                      ? null
                      : (row) => dlcOrderbookRowIsOwnWalletOpenOrder(
                          row: row,
                          isAskRow: true,
                          orders: state.orders,
                          orderbookSideRows: snapshot.asks,
                          selectedInstrumentId: resolvedId,
                        ),
                ),
                const SizedBox(height: 14),
                _OrderbookSideHeader(
                  label: 'Bids',
                  color: const Color(0xFF1B5E20),
                  showInfo: state.auth != null,
                  onInfoTap: onOwnOrdersInfoTap,
                ),
                const SizedBox(height: 6),
                _OrderbookDepthTable(
                  theme: theme,
                  colorScheme: colorScheme,
                  rows: snapshot.bids,
                  rowTextColor: const Color(0xFF1B5E20),
                  onRowTap: (row) {
                    Navigator.of(dialogContext).pop();
                    onDepthRowTap(
                      strikePrice: snapshot.strikePrice,
                      isAskRow: false,
                      row: row,
                    );
                  },
                  isOwnWalletRow: state.auth == null
                      ? null
                      : (row) => dlcOrderbookRowIsOwnWalletOpenOrder(
                          row: row,
                          isAskRow: false,
                          orders: state.orders,
                          orderbookSideRows: snapshot.bids,
                          selectedInstrumentId: resolvedId,
                        ),
                ),
                if (snapshot.asks.isEmpty && snapshot.bids.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'No open orders at this strike yet.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

/// Two-column depth table: price vs quantity (no side labels per row).
class _OrderbookDepthTable extends StatelessWidget {
  const _OrderbookDepthTable({
    required this.theme,
    required this.colorScheme,
    required this.rows,
    required this.rowTextColor,
    this.onRowTap,
    this.isOwnWalletRow,
  });

  final ThemeData theme;
  final ColorScheme colorScheme;
  final List<Map<String, dynamic>> rows;
  final Color rowTextColor;
  final void Function(Map<String, dynamic> row)? onRowTap;
  final bool Function(Map<String, dynamic> row)? isOwnWalletRow;

  @override
  Widget build(BuildContext context) {
    final subset = rows.take(10).toList(growable: false);
    if (subset.isEmpty) return const SizedBox.shrink();

    final borderColor = colorScheme.outlineVariant.withValues(alpha: 0.65);
    final headerStyle = theme.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w600,
      color: colorScheme.onSurface,
    );
    final baseCellStyle = theme.textTheme.bodyMedium?.copyWith(
      color: rowTextColor,
      fontWeight: FontWeight.w500,
    );

    TextStyle cellStyleFor(Map<String, dynamic> row) {
      final isOwn = isOwnWalletRow?.call(row) ?? false;
      if (!isOwn) return baseCellStyle!;
      return baseCellStyle!.copyWith(
        decoration: TextDecoration.underline,
        decorationStyle: TextDecorationStyle.dashed,
        decorationColor: rowTextColor,
      );
    }

    final tap = onRowTap;

    return Table(
      columnWidths: const {0: FlexColumnWidth(1), 1: FlexColumnWidth(1)},
      border: TableBorder(
        horizontalInside: BorderSide(color: borderColor),
        bottom: BorderSide(color: borderColor),
        verticalInside: BorderSide(color: borderColor),
      ),
      children: [
        TableRow(
          decoration: BoxDecoration(color: colorScheme.surfaceContainerHighest),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text('Premium per contract', style: headerStyle),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text('Number of contracts', style: headerStyle),
            ),
          ],
        ),
        ...subset.map(
          (row) {
            final rowStyle = cellStyleFor(row);
            return TableRow(
              children: [
                TableCell(
                  verticalAlignment: TableCellVerticalAlignment.middle,
                  child: InkWell(
                    onTap: tap == null ? null : () => tap(row),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Text(
                        dlcFormatGroupedSatoshis(
                          dlcOrderbookPremiumPerFullContractSatoshis(row),
                        ),
                        style: rowStyle,
                      ),
                    ),
                  ),
                ),
                TableCell(
                  verticalAlignment: TableCellVerticalAlignment.middle,
                  child: InkWell(
                    onTap: tap == null ? null : () => tap(row),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Text(
                        _orderbookQuantityLabel(row),
                        style: rowStyle,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _OrderbookSideHeader extends StatelessWidget {
  const _OrderbookSideHeader({
    required this.label,
    required this.color,
    required this.onInfoTap,
    this.showInfo = true,
  });

  final String label;
  final Color color;
  final VoidCallback onInfoTap;
  final bool showInfo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
        if (showInfo) ...[
          const SizedBox(width: 4),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: 'Your orders on the book',
            icon: Icon(Icons.info_outline, size: 18, color: color),
            onPressed: onInfoTap,
          ),
        ],
      ],
    );
  }
}

/// Orderbook depth for one instrument: highlights which contract is shown and
/// exposes a full-width instrument picker.
class _OrderbookInstrumentCard extends StatelessWidget {
  const _OrderbookInstrumentCard({
    required this.state,
    required this.selectedInstrument,
    required this.loading,
    required this.onDepthRowTap,
    required this.onOwnOrdersInfoTap,
  });

  final DlcState state;
  final Map<String, dynamic>? selectedInstrument;
  final bool loading;
  final void Function({
    required double strikePrice,
    required bool isAskRow,
    required Map<String, dynamic> row,
  })
  onDepthRowTap;
  final VoidCallback onOwnOrdersInfoTap;

  Future<void> _openPickerOverlay(BuildContext context) async {
    final cubit = context.read<DlcCubit>();
    var latestState = cubit.state;
    DlcOptionType draftOption = latestState.optionType;
    String? draftInstrumentId = latestState.selectedInstrumentId;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            final options = latestState.instruments
                .where((i) => dlcInstrumentMatchesOptionType(i, draftOption))
                .toList();
            if (!options.any((i) => dlcInstrumentId(i) == draftInstrumentId)) {
              draftInstrumentId = options.isEmpty
                  ? null
                  : dlcInstrumentId(options.first);
            }
            final selected = options.firstWhere(
              (i) => dlcInstrumentId(i) == draftInstrumentId,
              orElse: () =>
                  options.isNotEmpty ? options.first : <String, dynamic>{},
            );
            final oracle = (selected['oracle_label'] ?? '').toString().trim();
            final oracleText = oracle.isEmpty ? 'Unknown' : oracle;
            return AlertDialog(
              title: const Text('Change instrument'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Instruments use the oracle: $oracleText',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: draftInstrumentId,
                    isExpanded: true,
                    items: options
                        .map(
                          (i) => DropdownMenuItem(
                            value: dlcInstrumentId(i),
                            child: Text(dlcInstrumentLabel(i)),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => draftInstrumentId = value),
                    decoration: const InputDecoration(labelText: 'Instrument'),
                  ),
                  const SizedBox(height: 10),
                  ToggleButtons(
                    isSelected: [
                      draftOption == DlcOptionType.call,
                      draftOption == DlcOptionType.put,
                    ],
                    onPressed: (index) {
                      setState(() {
                        draftOption = index == 0
                            ? DlcOptionType.call
                            : DlcOptionType.put;
                      });
                    },
                    children: const [
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 14),
                        child: Text('Call'),
                      ),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 14),
                        child: Text('Put'),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Accept'),
                ),
              ],
            );
          },
        );
      },
    );
    if (accepted == true) {
      await cubit.selectOptionInstrumentAndStrike(
        optionType: draftOption,
        instrumentId: draftInstrumentId,
        strikePrice: null,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final rawId = selectedInstrument != null
        ? dlcInstrumentId(selectedInstrument!)
        : null;
    final expiry = selectedInstrument != null
        ? dlcInstrumentExpiresAt(selectedInstrument!)
        : null;
    String? optionLabel;
    String? underlyingLabel;
    if (selectedInstrument != null) {
      final metadata = dlcInstrumentMetadata(selectedInstrument!);
      underlyingLabel = metadata.underlying;
      final rawType = (selectedInstrument!['type'] ?? '')
          .toString()
          .toLowerCase();
      if (rawType == 'call' || rawType == 'c') {
        optionLabel = 'CALL';
      } else if (rawType == 'put' || rawType == 'p') {
        optionLabel = 'PUT';
      } else {
        final instrumentId = (dlcInstrumentId(selectedInstrument!) ?? '')
            .toUpperCase();
        if (instrumentId.endsWith('-C') || instrumentId.contains('CALL')) {
          optionLabel = 'CALL';
        } else if (instrumentId.endsWith('-P') ||
            instrumentId.contains('PUT')) {
          optionLabel = 'PUT';
        }
      }
    }
    final expiryText = expiry != null
        ? '${DateFormat.yMMMd().add_Hm().format(expiry.toUtc())} UTC'
        : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.menu_book_outlined, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Orderbook',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: loading ? null : () => _openPickerOverlay(context),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (rawId != null) ...[
                        RichText(
                          text: TextSpan(
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w700,
                            ),
                            children: [
                              TextSpan(text: _instrumentDisplayId(rawId)),
                              TextSpan(
                                text: ' (tap to change)',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (expiryText != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              [
                                ?underlyingLabel,
                                optionLabel ?? '-',
                                'Exp.: $expiryText',
                              ].join(' | '),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                      ] else
                        Text(
                          'No instrument selected — tap to choose.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Tap a strike to view full depth. Premiums are per contract (sats).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            if (loading && state.strikeOrderbooks.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (rawId != null) ...[
              _StrikeOrderbookSummaryTable(
                theme: theme,
                colorScheme: colorScheme,
                snapshots: state.strikeOrderbooks,
                onStrikeTap: loading
                    ? (_) {}
                    : (snapshot) {
                        _showStrikeOrderbookDetailDialog(
                          context: context,
                          state: state,
                          selectedInstrument: selectedInstrument,
                          snapshot: snapshot,
                          onDepthRowTap: onDepthRowTap,
                          onOwnOrdersInfoTap: onOwnOrdersInfoTap,
                        );
                      },
              ),
              if (!loading &&
                  state.strikeOrderbooks.isEmpty &&
                  state.suggestedStrikePrices.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'No liquidity on any strike yet.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ] else if (rawId == null)
              Text(
                'Select an instrument to view strikes.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
