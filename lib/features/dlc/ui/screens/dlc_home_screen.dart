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
  final _quantityController = TextEditingController(text: '0.01');
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
            .where(
              (i) => dlcInstrumentMatchesOptionType(i, state.optionType),
            )
            .toList();
        final initialInstrument = filteredInstruments.any(
          (instrument) =>
              (instrument['instrument_id'] ?? instrument['id']).toString() ==
              state.selectedInstrumentId,
        )
            ? state.selectedInstrumentId
            : null;
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

        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                  child: SegmentedButton<int>(
                    style: SegmentedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      foregroundColor: Theme.of(context).colorScheme.onSurface,
                      selectedBackgroundColor:
                          Theme.of(context).colorScheme.surfaceContainerLow,
                      selectedForegroundColor:
                          Theme.of(context).colorScheme.onSurface,
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
                              color: Theme.of(context).colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.error_outline,
                                  color: Theme.of(context).colorScheme.onErrorContainer,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    state.errorMessage!,
                                    style: TextStyle(
                                      color: Theme.of(context).colorScheme.onErrorContainer,
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
                              color: Theme.of(context).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    state.infoMessage!,
                                    style: TextStyle(
                                      color: Theme.of(context).colorScheme.onPrimaryContainer,
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
                                  Text(
                                    'Create order',
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 8),
                                  SegmentedButton<DlcOrderSide>(
                                    segments: const [
                                      ButtonSegment(value: DlcOrderSide.buy, label: Text('Buy')),
                                      ButtonSegment(value: DlcOrderSide.sell, label: Text('Sell')),
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
                                    keyboardType: const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                    decoration: const InputDecoration(
                                      labelText: 'Quantity (BTC)',
                                    ),
                                    onChanged: context.read<DlcCubit>().setQuantity,
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: _priceController,
                                    keyboardType: const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                    decoration: const InputDecoration(labelText: 'Strike price'),
                                    onChanged: context.read<DlcCubit>().setPrice,
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton.icon(
                                    onPressed: state.loading || state.auth == null
                                        ? null
                                        : () => context.read<DlcCubit>().createOrder(),
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
        if (state.auth == null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.person_add_alt_1_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Wallet registration',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Register only if you want this wallet on the DLC coordinator. Nothing is sent until you tap the button.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: state.loading
                        ? null
                        : () => context.read<DlcCubit>().registerWallet(),
                    icon: const Icon(Icons.link),
                    label: const Text('Register wallet'),
                  ),
                ],
              ),
            ),
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.verified_user_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Wallet registered',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Coordinator wallet ID',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    state.auth!.walletId,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (state.auth!.expiresAt != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Session expires (from API): ${DateFormat.yMMMd().add_jm().format(state.auth!.expiresAt!.toLocal())}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          'No dedicated events endpoint exposed by coordinator API yet.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
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
            Text(title, style: Theme.of(context).textTheme.titleSmall),
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
  });

  final String title;
  final String subtitle;
  final List<DlcOrderSummary> orders;
  final bool processingOrder;
  final bool allowFill;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              allowFill ? Icons.pending_actions_outlined : Icons.task_alt_outlined,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 2),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        if (orders.isEmpty)
          Card(
            child: ListTile(
              dense: true,
              title: const Text('No orders in this section'),
            ),
          )
        else
          ...orders.map(
            (order) => Card(
              child: ListTile(
                title: Text('Order ${order.orderId}'),
                subtitle: Text(
                  'Status: ${order.status}${order.dlcId != null ? '\nDLC: ${order.dlcId}' : ''}',
                ),
                trailing: allowFill
                    ? ElevatedButton(
                        onPressed: processingOrder
                            ? null
                            : () => context.read<DlcCubit>().fulfillOrder(order.orderId),
                        child: const Text('Fill'),
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

bool _isOpenOrder(DlcOrderSummary order) {
  final status = order.status.toLowerCase();
  return status == 'open' || status == 'pending_accept' || order.pendingMatchAccept;
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

/// Orderbook depth for one instrument: highlights which contract is shown and
/// exposes a full-width instrument picker.
class _OrderbookInstrumentCard extends StatelessWidget {
  const _OrderbookInstrumentCard({
    required this.state,
    required this.filteredInstruments,
    required this.initialInstrument,
    required this.selectedInstrument,
    required this.loading,
  });

  final DlcState state;
  final List<Map<String, dynamic>> filteredInstruments;
  final String? initialInstrument;
  final Map<String, dynamic>? selectedInstrument;
  final bool loading;

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
    final expiryText = expiry != null
        ? '${DateFormat.yMMMd().format(expiry.toUtc())} UTC'
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
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Bids and asks below are for the instrument you select.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LISTING ORDERBOOK FOR',
                      style: theme.textTheme.labelSmall?.copyWith(
                        letterSpacing: 0.5,
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (id != null) ...[
                      SelectableText(
                        id,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (selectedInstrument!['oracle_label'] != null &&
                          selectedInstrument!['oracle_label']
                              .toString()
                              .trim()
                              .isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Oracle: ${selectedInstrument!['oracle_label']}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (expiryText != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'Expiry: $expiryText',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ] else
                      Text(
                        'No instrument selected — pick one under “Change instrument”.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Change instrument',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Choose which contract’s orderbook to view (from coordinator API).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: ValueKey<String?>(
                '${state.optionType.name}_${state.selectedInstrumentId}',
              ),
              initialValue: initialInstrument,
              isExpanded: true,
              items: filteredInstruments
                  .map(
                    (instrument) => DropdownMenuItem(
                      value: dlcInstrumentId(instrument),
                      child: Text(
                        dlcInstrumentLabel(instrument),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: loading
                  ? null
                  : (value) => context.read<DlcCubit>().setInstrument(value),
              decoration: InputDecoration(
                filled: true,
                labelText: 'Instrument',
                hintText: 'Select contract',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Option type',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            ToggleButtons(
              isSelected: [
                state.optionType == DlcOptionType.call,
                state.optionType == DlcOptionType.put,
              ],
              onPressed: loading
                  ? null
                  : (index) {
                      context.read<DlcCubit>().setOptionType(
                        index == 0 ? DlcOptionType.call : DlcOptionType.put,
                      );
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
                      id,
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
            ...state.orderbookAsks.take(10).map(
              (ask) => ListTile(
                dense: true,
                leading: const Text('ASK'),
                title: Text(
                  'Price ${ask['price']} — Qty ${ask['quantity'] ?? ask['amount'] ?? '-'}',
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
                      id,
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
            ...state.orderbookBids.take(10).map(
              (bid) => ListTile(
                dense: true,
                leading: const Text('BID'),
                title: Text(
                  'Price ${bid['price']} — Qty ${bid['quantity'] ?? bid['amount'] ?? '-'}',
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
