import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/presentation/dlc_cubit.dart';
import 'package:bb_mobile/features/dlc/presentation/dlc_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class DlcHomeScreen extends StatefulWidget {
  const DlcHomeScreen({super.key});

  @override
  State<DlcHomeScreen> createState() => _DlcHomeScreenState();
}

class _DlcHomeScreenState extends State<DlcHomeScreen> {
  final _quantityController = TextEditingController(text: '0.01');
  final _priceController = TextEditingController(text: '0');

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
        final filteredInstruments = state.instruments.where((instrument) {
          final id = (instrument['instrument_id'] ?? instrument['id'] ?? '')
              .toString()
              .toUpperCase();
          return id.contains(state.optionType.value);
        }).toList();
        final initialInstrument = filteredInstruments.any(
          (instrument) =>
              (instrument['instrument_id'] ?? instrument['id']).toString() ==
              state.selectedInstrumentId,
        )
            ? state.selectedInstrumentId
            : null;

        return Scaffold(
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: context.read<DlcCubit>().load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'DLCs',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  if (state.auth == null)
                    ElevatedButton(
                      onPressed: state.loading
                          ? null
                          : () => context.read<DlcCubit>().registerWallet(),
                      child: const Text('Register wallet'),
                    )
                  else
                    Card(
                      child: ListTile(
                        title: const Text('Wallet registered'),
                        subtitle: Text('Wallet ID: ${state.auth!.walletId}'),
                      ),
                    ),
                  if (state.errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      state.errorMessage!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  if (state.infoMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(state.infoMessage!),
                  ],
                  const SizedBox(height: 16),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('Orderbook')),
                      ButtonSegment(value: 1, label: Text('My Orders')),
                    ],
                    selected: {state.selectedTabIndex},
                    onSelectionChanged: state.loading
                        ? null
                        : (selection) =>
                              context.read<DlcCubit>().setTab(selection.first),
                  ),
                  const SizedBox(height: 12),
                  if (state.selectedTabIndex == 0) ...[
                    Card(
                      child: ListTile(
                        title: const Text('Available balance'),
                        subtitle: Text('${state.availableBalanceSat ?? 0} sats'),
                        trailing: Text('Reserved: ${state.reservedBalanceSat ?? 0}'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Create Order',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<DlcOptionType>(
                      segments: const [
                        ButtonSegment(value: DlcOptionType.call, label: Text('CALL')),
                        ButtonSegment(value: DlcOptionType.put, label: Text('PUT')),
                      ],
                      selected: {state.optionType},
                      onSelectionChanged: state.loading
                          ? null
                          : (selection) =>
                                context.read<DlcCubit>().setOptionType(selection.first),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: initialInstrument,
                      items: filteredInstruments
                          .map(
                            (instrument) => DropdownMenuItem(
                              value: (instrument['instrument_id'] ?? instrument['id'])
                                  ?.toString(),
                              child: Text(
                                (instrument['instrument_id'] ??
                                        instrument['id'] ??
                                        'instrument')
                                    .toString(),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: state.loading
                          ? null
                          : (value) => context.read<DlcCubit>().setInstrument(value),
                      decoration: const InputDecoration(labelText: 'Instrument'),
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
                          : (selection) =>
                                context.read<DlcCubit>().setSide(selection.first),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _quantityController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Quantity (BTC)'),
                      onChanged: context.read<DlcCubit>().setQuantity,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _priceController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Strike price'),
                      onChanged: context.read<DlcCubit>().setPrice,
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: state.loading || state.auth == null
                          ? null
                          : () => context.read<DlcCubit>().createOrder(),
                      child: state.loading
                          ? const CircularProgressIndicator()
                          : const Text('Create'),
                    ),
                    const SizedBox(height: 16),
                    Text('Orderbook', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    ...state.orderbookAsks.take(10).map(
                      (ask) => ListTile(
                        dense: true,
                        leading: const Text('ASK'),
                        title: Text(
                          'Price ${ask['price']} - Qty ${ask['quantity'] ?? ask['amount'] ?? '-'}',
                        ),
                      ),
                    ),
                    ...state.orderbookBids.take(10).map(
                      (bid) => ListTile(
                        dense: true,
                        leading: const Text('BID'),
                        title: Text(
                          'Price ${bid['price']} - Qty ${bid['quantity'] ?? bid['amount'] ?? '-'}',
                        ),
                      ),
                    ),
                  ] else ...[
                    Text(
                      'My Orders',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    ...state.orders.map(
                      (order) => Card(
                        child: ListTile(
                          title: Text('Order ${order.orderId}'),
                          subtitle: Text(
                            'Status: ${order.status}${order.dlcId != null ? '\nDLC: ${order.dlcId}' : ''}',
                          ),
                          trailing: ElevatedButton(
                            onPressed: state.processingOrder
                                ? null
                                : () => context.read<DlcCubit>().fulfillOrder(order.orderId),
                            child: const Text('Fill'),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
