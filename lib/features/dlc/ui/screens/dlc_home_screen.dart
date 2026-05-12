import 'package:bb_mobile/features/dlc/domain/dlc_instrument_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/presentation/dlc_cubit.dart';
import 'package:bb_mobile/features/dlc/presentation/dlc_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

class DlcHomeScreen extends StatefulWidget {
  const DlcHomeScreen({super.key});

  @override
  State<DlcHomeScreen> createState() => _DlcHomeScreenState();
}

class _DlcHomeScreenState extends State<DlcHomeScreen> {
  final _quantityController = TextEditingController(text: '10000');
  final _priceController = TextEditingController(text: '0');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Loads instruments and orderbook only; wallet registration is explicit.
      context.read<DlcCubit>().load();
    });
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _priceController.dispose();
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
            .where((o) => _isOpenOrder(o))
            .toList(growable: false);
        final liveOrders = state.orders
            .where((o) => _isLiveOrder(o))
            .toList(growable: false);
        final closedOrders = state.orders
            .where((o) => _isClosedOrder(o))
            .toList(growable: false);
        final tradingBlocked = _tradingBlocked(state);

        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                  ),
                  child: SegmentedButton<int>(
                    style: SegmentedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      foregroundColor: Theme.of(context).colorScheme.onSurface,
                      selectedBackgroundColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerLow,
                      selectedForegroundColor: Theme.of(
                        context,
                      ).colorScheme.onSurface,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero,
                      ),
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(
                        value: 0,
                        icon: Icon(Icons.dashboard_outlined, size: 18),
                        label: Text('Overview'),
                      ),
                      ButtonSegment(
                        value: 1,
                        icon: Icon(Icons.menu_book_outlined, size: 18),
                        label: Text('Orderbook'),
                      ),
                      ButtonSegment(
                        value: 2,
                        icon: Icon(Icons.list_alt_outlined, size: 18),
                        label: Text('My Orders'),
                      ),
                    ],
                    selected: {state.selectedTabIndex},
                    onSelectionChanged: state.loading
                        ? null
                        : (selection) {
                            final idx = selection.first;
                            context.read<DlcCubit>().setTab(idx);
                            if (idx == 1) {
                              context.read<DlcCubit>().refreshInstruments();
                            }
                          },
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: context.read<DlcCubit>().load,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (state.errorMessage != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.error_outline,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onErrorContainer,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    state.errorMessage!,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onErrorContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (state.infoMessage != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimaryContainer,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    state.infoMessage!,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        if (state.selectedTabIndex == 0) ...[
                          _OverviewPanel(state: state),
                        ] else if (state.selectedTabIndex == 1) ...[
                          _OrderbookInstrumentCard(
                            state: state,
                            selectedInstrument: selectedForOrderbook,
                            loading: state.loading,
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
                                  TextField(
                                    controller: _quantityController,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: const InputDecoration(
                                      labelText: 'Quantity',
                                      helperText:
                                          'Exact quantity only. Partial fills are not supported.',
                                    ),
                                    onChanged: context
                                        .read<DlcCubit>()
                                        .setQuantity,
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: _priceController,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: const InputDecoration(
                                      labelText: 'Limit price (optional)',
                                      helperText:
                                          'For -STRIKE- templates this field is also used as the strike when placing the order.',
                                    ),
                                    onChanged: context
                                        .read<DlcCubit>()
                                        .setPrice,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Matching is exact quantity only (no partial fills). '
                                    '“Filled” on an order is a market state, not guaranteed economic settlement.',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton.icon(
                                    onPressed:
                                        state.loading ||
                                            state.auth == null ||
                                            tradingBlocked
                                        ? null
                                        : () => context
                                              .read<DlcCubit>()
                                              .createOrder(),
                                    icon: const Icon(Icons.add_chart),
                                    label: state.loading
                                        ? const Text('Creating...')
                                        : const Text('Create'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ] else ...[
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
                            subtitle: 'Filled, settlement/attestation pending',
                            orders: liveOrders,
                            processingOrder: state.processingOrder,
                          ),
                          const SizedBox(height: 12),
                          _OrderGroupSection(
                            title: 'Closed / settled',
                            subtitle: 'Completed DLCs and finalized orders',
                            orders: closedOrders,
                            processingOrder: state.processingOrder,
                            allowFill: false,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
    final inOrders = state.orders.length.toDouble();
    final openCount = state.orders.where(_isOpenOrder).length.toDouble();
    final liveCount = state.orders.where(_isLiveOrder).length.toDouble();
    final closedCount = state.orders.where(_isClosedOrder).length.toDouble();

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
                      state.auth == null
                          ? Icons.person_add_alt_1_outlined
                          : Icons.verified_user_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      state.auth == null
                          ? 'Wallet registration'
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
                    'Register only if you want this wallet on the DLC coordinator. Nothing is sent until you tap the button.',
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
                          (wallet) => DropdownMenuItem(
                            value: wallet.walletOriginId,
                            child: Text(wallet.label),
                          ),
                        )
                        .toList(),
                    onChanged: state.loading
                        ? null
                        : (value) {
                            if (value == null) return;
                            context.read<DlcCubit>().setRegistrationWallet(
                              value,
                            );
                          },
                    decoration: const InputDecoration(
                      labelText: 'Bitcoin wallet to register',
                    ),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed:
                        state.loading ||
                            state.selectedRegistrationWalletOriginId == null
                        ? null
                        : () => context.read<DlcCubit>().registerWallet(),
                    icon: const Icon(Icons.link),
                    label: const Text('Register wallet'),
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
        _BarStatCard(
          title: 'Balance split',
          leftLabel: 'Available',
          leftValue: state.availableBalanceSat ?? 0,
          rightLabel: 'Reserved',
          rightValue: state.reservedBalanceSat ?? 0,
          leftRatio: total <= 0 ? 0 : available / total,
        ),
        const SizedBox(height: 8),
        _BarStatCard(
          title: 'Order status mix',
          leftLabel: 'Open',
          leftValue: openCount.toInt(),
          rightLabel: 'Live',
          rightValue: liveCount.toInt(),
          leftRatio: inOrders <= 0 ? 0 : openCount / inOrders,
        ),
        const SizedBox(height: 8),
        _BarStatCard(
          title: 'Settlement progress',
          leftLabel: 'Closed',
          leftValue: closedCount.toInt(),
          rightLabel: 'Non-closed',
          rightValue: (openCount + liveCount).toInt(),
          leftRatio: inOrders <= 0 ? 0 : closedCount / inOrders,
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
    String draftOriginId = auth.walletOriginId;
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
                  const SizedBox(height: 6),
                  SelectableText('Wallet ID: ${auth.walletId}'),
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
                    items: state.registeredWalletAuths
                        .map(
                          (item) => DropdownMenuItem(
                            value: item.walletOriginId,
                            child: Text(item.walletLabel),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => draftOriginId = value);
                    },
                    decoration: const InputDecoration(
                      labelText: 'Switch active registered wallet',
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
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Switch'),
                ),
              ],
            );
          },
        );
      },
    );
    if (changed == true && draftOriginId != auth.walletOriginId) {
      // ignore: use_build_context_synchronously
      await context.read<DlcCubit>().switchActiveWallet(draftOriginId);
    }
  }
}

class _BarStatCard extends StatelessWidget {
  const _BarStatCard({
    required this.title,
    required this.leftLabel,
    required this.leftValue,
    required this.rightLabel,
    required this.rightValue,
    required this.leftRatio,
  });

  final String title;
  final String leftLabel;
  final int leftValue;
  final String rightLabel;
  final int rightValue;
  final double leftRatio;

  @override
  Widget build(BuildContext context) {
    final ratio = leftRatio.clamp(0, 1).toDouble();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
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
    this.allowFill = true,
    this.showCancel = false,
  });

  final String title;
  final String subtitle;
  final List<DlcOrderSummary> orders;
  final bool processingOrder;
  final bool allowFill;
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
                  allowFill
                      ? Icons.pending_actions_outlined
                      : Icons.task_alt_outlined,
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
                (order) => ListTile(
                  title: Text('Order ${order.orderId}'),
                  subtitle: Text(_formatOrderSummary(order)),
                  trailing: allowFill
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (showCancel)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: OutlinedButton(
                                  onPressed: processingOrder
                                      ? null
                                      : () => context
                                            .read<DlcCubit>()
                                            .cancelOpenOrder(order.orderId),
                                  child: const Text('Cancel'),
                                ),
                              ),
                            OutlinedButton(
                              onPressed: processingOrder
                                  ? null
                                  : () => context
                                        .read<DlcCubit>()
                                        .processOrderLifecycle(order.orderId),
                              child: const Text('Continue'),
                            ),
                          ],
                        )
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _formatOrderSummary(DlcOrderSummary order) {
  final lines = <String>[];
  if (order.instrumentId != null && order.instrumentId!.isNotEmpty) {
    lines.add('Instrument: ${order.instrumentId}');
  }
  final side = order.side;
  final qty = order.quantity;
  if (side != null || qty != null || order.price != null) {
    final qtyStr = qty != null ? qty.toStringAsFixed(0) : '-';
    final priceStr = order.price != null ? ' · Limit: ${order.price}' : '';
    lines.add('Side: ${side ?? '-'} · Quantity: $qtyStr$priceStr');
  }
  lines.add('Order status: ${order.status}');
  if (order.dlcStatus != null) lines.add('DLC status: ${order.dlcStatus}');
  if (order.signRequired == true) {
    lines.add('Action required: maker sign');
  }
  if (order.confirmationStatus != null) {
    lines.add('Confirmation: ${order.confirmationStatus}');
  }
  if (order.settlementType != null) {
    lines.add('Settlement: ${order.settlementType}');
  }
  if (order.dlcId != null) lines.add('DLC: ${order.dlcId}');
  if (order.fundingTxid != null) {
    lines.add('Funding txid: ${order.fundingTxid}');
  }
  if (order.oracleOutcomeValue != null) {
    lines.add('Oracle outcome: ${order.oracleOutcomeValue}');
  }
  if (order.lastErrorReason != null) {
    final msg = order.lastErrorMessage;
    lines.add(
      msg != null && msg.isNotEmpty
          ? 'Last error: ${order.lastErrorReason} — $msg'
          : 'Last error: ${order.lastErrorReason}',
    );
  }
  return lines.join('\n');
}

bool _isOpenOrder(DlcOrderSummary order) {
  final status = order.status.toLowerCase();
  return status == 'open' ||
      status == 'pending_accept' ||
      order.pendingMatchAccept;
}

bool _isClosedOrder(DlcOrderSummary order) {
  final status = order.status.toLowerCase();
  return status.contains('closed') ||
      status.contains('settled') ||
      status == 'cancelled' ||
      status == 'expired' ||
      status == 'rejected' ||
      status == 'terminated';
}

bool _isLiveOrder(DlcOrderSummary order) {
  if (_isOpenOrder(order) || _isClosedOrder(order)) return false;
  final status = order.status.toLowerCase();
  return status == 'filled' ||
      status == 'accepted' ||
      status == 'signed' ||
      status == 'attested' ||
      status == 'matured' ||
      status == 'cet_broadcasted' ||
      status == 'refund_broadcasted' ||
      order.dlcId != null;
}

bool _tradingBlocked(DlcState state) {
  final hint = state.coordinatorTradingHint?.toLowerCase() ?? '';
  return hint.contains('switch the app environment') ||
      hint.contains('does not report testnet') ||
      hint.contains('reports regtest while this app environment is mainnet');
}

String _instrumentDisplayId(String? rawId) {
  if (rawId == null || rawId.isEmpty) return '-';
  return rawId.replaceAll('-STRIKE-', '-');
}

/// Orderbook depth for one instrument: highlights which contract is shown and
/// exposes a full-width instrument picker.
class _OrderbookInstrumentCard extends StatelessWidget {
  const _OrderbookInstrumentCard({
    required this.state,
    required this.selectedInstrument,
    required this.loading,
  });

  final DlcState state;
  final Map<String, dynamic>? selectedInstrument;
  final bool loading;

  Future<void> _openPickerOverlay(BuildContext context) async {
    DlcOptionType draftOption = state.optionType;
    String? draftInstrumentId = state.selectedInstrumentId;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            final options = state.instruments
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
                            child: Text(
                              _instrumentDisplayId(dlcInstrumentId(i)),
                            ),
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
      context.read<DlcCubit>().setOptionType(draftOption);
      if (draftInstrumentId != null) {
        context.read<DlcCubit>().setInstrument(draftInstrumentId);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final id = selectedInstrument != null
        ? dlcInstrumentId(selectedInstrument!)
        : null;
    final expiry = selectedInstrument != null
        ? dlcInstrumentExpiresAt(selectedInstrument!)
        : null;
    String? optionLabel;
    String? strikeLabel;
    String? underlyingLabel;
    if (selectedInstrument != null) {
      final metadata = dlcInstrumentMetadata(selectedInstrument!);
      strikeLabel = metadata.strike;
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
                      Text(
                        'LISTING ORDERBOOK FOR (click to change)',
                        style: theme.textTheme.labelSmall?.copyWith(
                          letterSpacing: 0.5,
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (id != null) ...[
                        SelectableText(
                          _instrumentDisplayId(id),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (expiryText != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              [
                                ?underlyingLabel,
                                optionLabel ?? '-',
                                ?(strikeLabel == null
                                    ? null
                                    : 'Strike: $strikeLabel'),
                                'Expiry: $expiryText',
                              ].join(' | '),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
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
            const SizedBox(height: 20),
            if (id != null) ...[
              Row(
                children: [
                  Text(
                    'Asks',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colorScheme.error,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _instrumentDisplayId(id),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
            ...state.orderbookAsks
                .take(10)
                .map(
                  (ask) => ListTile(
                    dense: true,
                    leading: const Text('ASK'),
                    title: Text(
                      'Price ${ask['price']} — Quantity ${ask['quantity'] ?? ask['amount'] ?? '-'}',
                    ),
                  ),
                ),
            if (id != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    'Bids',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colorScheme.tertiary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _instrumentDisplayId(id),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
            ...state.orderbookBids
                .take(10)
                .map(
                  (bid) => ListTile(
                    dense: true,
                    leading: const Text('BID'),
                    title: Text(
                      'Price ${bid['price']} — Quantity ${bid['quantity'] ?? bid['amount'] ?? '-'}',
                    ),
                  ),
                ),
            if (id != null &&
                state.orderbookAsks.isEmpty &&
                state.orderbookBids.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'No open orders on this book yet.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
