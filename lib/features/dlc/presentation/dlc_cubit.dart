import 'dart:async';

import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bb_mobile/features/dlc/data/dlc_repository.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_instrument_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/presentation/dlc_state.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class DlcCubit extends Cubit<DlcState> {
  final DlcRepository _repository;
  Timer? _liveOrderPollTimer;
  bool _pollInFlight = false;

  DlcCubit({required DlcRepository repository})
    : _repository = repository,
      super(DlcState.initial());

  Future<void> load() async {
    emit(state.copyWith(loading: true, clearError: true, clearInfo: true));
    try {
      Map<String, dynamic>? readiness;
      var readinessFailed = false;
      try {
        readiness = await _repository.getSystemReadiness();
      } catch (_) {
        readinessFailed = true;
      }
      final appEnv = await _repository.getAppEnvironment();
      final tradingHint = _buildCoordinatorTradingHint(
        environment: appEnv,
        readiness: readiness,
        readinessFailed: readinessFailed,
      );

      final instruments = await _repository.listInstruments();
      final wallets = await _repository.listBitcoinWalletOptions();
      final validation = await _repository.validateAndLoadWalletAuths();
      final auth = validation.activeAuth;
      final registeredWalletAuths = await _repository.getAllWalletAuths();
      final sessionInfo = validation.expiredWallets.isNotEmpty
          ? 'Some registered DLC wallets expired and were archived below.'
          : null;
      final orders = auth == null
          ? <DlcOrderSummary>[]
          : await _repository.listOrders();
      final balances = auth == null
          ? null
          : await _repository.getWalletBalances();
      final filteredForBook = instruments
          .where((i) => dlcInstrumentMatchesOptionType(i, state.optionType))
          .toList();
      final selectedInstrument = filteredForBook.isEmpty
          ? null
          : dlcInstrumentId(filteredForBook.first);
      final orderbook = selectedInstrument == null
          ? <String, dynamic>{}
          : await _repository.getOrderbook(selectedInstrument);
      emit(
        state.copyWith(
          loading: false,
          auth: auth,
          instruments: instruments,
          orders: orders,
          clearSelectedInstrument: selectedInstrument == null,
          selectedInstrumentId: selectedInstrument,
          totalBalanceSat: (balances?['total_balance'] as num?)?.toInt(),
          availableBalanceSat: (balances?['available_balance'] as num?)
              ?.toInt(),
          reservedBalanceSat: (balances?['reserved_balance'] as num?)?.toInt(),
          orderbookBids: (orderbook['bids'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
          orderbookAsks: (orderbook['asks'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
          infoMessage: sessionInfo,
          availableWallets: wallets,
          selectedRegistrationWalletOriginId:
              state.selectedRegistrationWalletOriginId ??
              (wallets.isEmpty ? null : wallets.first.walletOriginId),
          expiredWallets: validation.expiredWallets,
          registeredWalletAuths: registeredWalletAuths,
          coordinatorReadiness: readiness,
          coordinatorReadinessFailed: readinessFailed,
          coordinatorTradingHint: tradingHint,
        ),
      );
      _configureLiveOrderPolling(orders);
    } catch (e) {
      emit(
        state.copyWith(
          loading: false,
          errorMessage: 'Failed to load DLC data: $e',
        ),
      );
    }
  }

  Future<void> registerWallet() async {
    emit(state.copyWith(loading: true, clearError: true, clearInfo: true));
    try {
      final walletOriginId = state.selectedRegistrationWalletOriginId;
      if (walletOriginId == null) {
        throw Exception('No Bitcoin wallet selected');
      }
      final auth = await _repository.registerWalletByOriginId(walletOriginId);
      final orders = await _repository.listOrders();
      final registeredWalletAuths = await _repository.getAllWalletAuths();
      emit(
        state.copyWith(
          loading: false,
          auth: auth,
          orders: orders,
          infoMessage: 'Wallet registered successfully.',
          registeredWalletAuths: registeredWalletAuths,
        ),
      );
      _configureLiveOrderPolling(orders);
    } catch (e) {
      emit(
        state.copyWith(
          loading: false,
          errorMessage: 'Wallet registration failed: $e',
        ),
      );
    }
  }

  void setInstrument(String? instrumentId) {
    emit(state.copyWith(selectedInstrumentId: instrumentId, clearError: true));
    if (instrumentId != null) {
      // ignore: discarded_futures
      _refreshOrderbook(instrumentId);
    }
  }

  void setSide(DlcOrderSide side) {
    emit(state.copyWith(side: side, clearError: true));
  }

  void setRegistrationWallet(String walletOriginId) {
    emit(
      state.copyWith(
        selectedRegistrationWalletOriginId: walletOriginId,
        clearError: true,
      ),
    );
  }

  Future<void> switchActiveWallet(String walletOriginId) async {
    emit(state.copyWith(loading: true, clearError: true, clearInfo: true));
    try {
      await _repository.setActiveWalletOriginId(walletOriginId);
      await load();
      emit(
        state.copyWith(
          loading: false,
          infoMessage: 'Active DLC wallet switched.',
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(
          loading: false,
          errorMessage: 'Failed to switch DLC wallet: $e',
        ),
      );
    }
  }

  void setOptionType(DlcOptionType optionType) {
    final filtered = state.instruments
        .where((i) => dlcInstrumentMatchesOptionType(i, optionType))
        .toList();
    String? nextId;
    if (filtered.isEmpty) {
      nextId = null;
    } else {
      final current = state.selectedInstrumentId;
      nextId =
          current != null && filtered.any((i) => dlcInstrumentId(i) == current)
          ? current
          : dlcInstrumentId(filtered.first);
    }
    emit(
      state.copyWith(
        optionType: optionType,
        clearSelectedInstrument: nextId == null,
        selectedInstrumentId: nextId,
        clearError: true,
      ),
    );
    if (nextId != null) {
      // ignore: discarded_futures
      _refreshOrderbook(nextId);
    }
  }

  /// Refetches non-expired instruments from the coordinator and refreshes the orderbook.
  Future<void> refreshInstruments() async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final instruments = await _repository.listInstruments();
      final filtered = instruments
          .where((i) => dlcInstrumentMatchesOptionType(i, state.optionType))
          .toList();
      var selectedId = state.selectedInstrumentId;
      if (selectedId == null ||
          !filtered.any((i) => dlcInstrumentId(i) == selectedId)) {
        selectedId = filtered.isEmpty ? null : dlcInstrumentId(filtered.first);
      }
      Map<String, dynamic> orderbook = {};
      if (selectedId != null) {
        orderbook = await _repository.getOrderbook(selectedId);
      }
      emit(
        state.copyWith(
          loading: false,
          instruments: instruments,
          clearSelectedInstrument: selectedId == null,
          selectedInstrumentId: selectedId,
          orderbookBids: (orderbook['bids'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
          orderbookAsks: (orderbook['asks'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(
          loading: false,
          errorMessage: 'Failed to refresh instruments: $e',
        ),
      );
    }
  }

  void setTab(int index) {
    emit(state.copyWith(selectedTabIndex: index));
    if (index == 2) {
      _configureLiveOrderPolling(state.orders);
    }
  }

  void setQuantity(String quantity) {
    emit(
      state.copyWith(
        quantity: double.tryParse(quantity) ?? state.quantity,
        clearError: true,
      ),
    );
  }

  void setPrice(String price) {
    emit(
      state.copyWith(
        price: double.tryParse(price) ?? state.price,
        clearError: true,
      ),
    );
  }

  Future<void> createOrder() async {
    emit(state.copyWith(loading: true, clearError: true, clearInfo: true));
    try {
      if (state.selectedInstrumentId == null) {
        throw Exception('Please select an instrument');
      }
      final auth = state.auth;
      if (auth == null) {
        throw Exception('Register your wallet before creating an order');
      }

      final draft = DlcOrderDraft(
        instrumentId: state.selectedInstrumentId!,
        side: state.side,
        quantity: state.quantity,
        price: state.price,
        fundingPubkeyHex: '',
      );
      final created = await _repository.createOrder(draft);
      await _repository.progressOrderLifecycle(orderId: created.orderId);
      final orders = await _repository.listOrders();
      final balances = await _repository.getWalletBalances();
      final selectedInstrument = state.selectedInstrumentId;
      final orderbook = selectedInstrument == null
          ? <String, dynamic>{}
          : await _repository.getOrderbook(selectedInstrument);
      emit(
        state.copyWith(
          loading: false,
          orders: orders,
          totalBalanceSat: (balances?['total_balance'] as num?)?.toInt(),
          availableBalanceSat: (balances?['available_balance'] as num?)
              ?.toInt(),
          reservedBalanceSat: (balances?['reserved_balance'] as num?)?.toInt(),
          orderbookBids: (orderbook['bids'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
          orderbookAsks: (orderbook['asks'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
          infoMessage: 'Order created.',
        ),
      );
      _configureLiveOrderPolling(orders);
    } catch (e) {
      final message = e.toString();
      final lower = message.toLowerCase();
      final notEnoughBalance =
          message.toLowerCase().contains('insufficient available balance') ||
          lower.contains('insufficient') ||
          lower.contains('not enough');
      final strikeRequired =
          lower.contains('strike price is required') ||
          lower.contains('resolved instrument_id') ||
          lower.contains('strike instruments');
      final partner403 =
          lower.contains('403') &&
          (lower.contains('partner') || lower.contains('x-partner-token'));
      emit(
        state.copyWith(
          loading: false,
          errorMessage: partner403
              ? 'Coordinator rejected the request (403). Check DLC_COORDINATOR_PARTNER_TOKEN and coordinator configuration.'
              : strikeRequired
              ? 'Select a strike price greater than 0 before creating this order.'
              : notEnoughBalance
              ? 'Not enough balance'
              : 'Create order failed: $e',
        ),
      );
    }
  }

  Future<void> cancelOpenOrder(String orderId) async {
    emit(
      state.copyWith(processingOrder: true, clearError: true, clearInfo: true),
    );
    try {
      await _repository.cancelOrder(orderId);
      final orders = await _repository.listOrders();
      emit(
        state.copyWith(
          processingOrder: false,
          orders: orders,
          infoMessage: 'Order cancelled.',
        ),
      );
      _configureLiveOrderPolling(orders);
    } catch (e) {
      emit(
        state.copyWith(
          processingOrder: false,
          errorMessage: 'Cancel failed: $e',
        ),
      );
    }
  }

  Future<void> fulfillOrder(String orderId) async {
    emit(
      state.copyWith(processingOrder: true, clearError: true, clearInfo: true),
    );
    try {
      await _repository.fillAndProcessOrder(orderId: orderId);
      final orders = await _repository.listOrders();
      final balances = await _repository.getWalletBalances();
      final selectedInstrument = state.selectedInstrumentId;
      final orderbook = selectedInstrument == null
          ? <String, dynamic>{}
          : await _repository.getOrderbook(selectedInstrument);
      emit(
        state.copyWith(
          processingOrder: false,
          orders: orders,
          totalBalanceSat: (balances?['total_balance'] as num?)?.toInt(),
          availableBalanceSat: (balances?['available_balance'] as num?)
              ?.toInt(),
          reservedBalanceSat: (balances?['reserved_balance'] as num?)?.toInt(),
          orderbookBids: (orderbook['bids'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
          orderbookAsks: (orderbook['asks'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
          infoMessage: 'Order fulfill process finished.',
        ),
      );
      _configureLiveOrderPolling(orders);
    } catch (e) {
      emit(
        state.copyWith(
          processingOrder: false,
          errorMessage: 'Order fulfill failed: $e',
        ),
      );
    }
  }

  Future<void> processOrderLifecycle(String orderId) async {
    emit(
      state.copyWith(processingOrder: true, clearError: true, clearInfo: true),
    );
    try {
      await _repository.progressOrderLifecycle(orderId: orderId);
      final orders = await _repository.listOrders();
      emit(
        state.copyWith(
          processingOrder: false,
          orders: orders,
          infoMessage: 'Order lifecycle processed.',
        ),
      );
      _configureLiveOrderPolling(orders);
    } catch (e) {
      emit(
        state.copyWith(
          processingOrder: false,
          errorMessage: 'Order lifecycle processing failed: $e',
        ),
      );
    }
  }

  Future<void> _refreshOrderbook(String instrumentId) async {
    try {
      final orderbook = await _repository.getOrderbook(instrumentId);
      emit(
        state.copyWith(
          orderbookBids: (orderbook['bids'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
          orderbookAsks: (orderbook['asks'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
        ),
      );
    } catch (_) {
      // Keep current orderbook snapshot on refresh failures.
    }
  }

  void _configureLiveOrderPolling(List<DlcOrderSummary> orders) {
    final shouldPoll = state.auth != null && orders.any(_isLiveLikeOrder);
    if (shouldPoll) {
      _liveOrderPollTimer ??= Timer.periodic(
        const Duration(seconds: 15),
        (_) => _pollLiveOrders(),
      );
    } else {
      _liveOrderPollTimer?.cancel();
      _liveOrderPollTimer = null;
    }
  }

  bool _isLiveLikeOrder(DlcOrderSummary order) {
    final status = order.status.toLowerCase();
    final isClosed =
        status.contains('closed') ||
        status.contains('settled') ||
        status == 'cancelled' ||
        status == 'expired' ||
        status == 'rejected' ||
        status == 'terminated';
    return !isClosed;
  }

  Future<void> _pollLiveOrders() async {
    if (_pollInFlight || isClosed || state.processingOrder || state.loading) {
      return;
    }
    _pollInFlight = true;
    try {
      final orders = await _repository.listOrders();
      if (!isClosed) {
        emit(state.copyWith(orders: orders));
        _configureLiveOrderPolling(orders);
      }
    } catch (_) {
      // Keep polling in case the next tick succeeds.
    } finally {
      _pollInFlight = false;
    }
  }

  @override
  Future<void> close() {
    _liveOrderPollTimer?.cancel();
    _liveOrderPollTimer = null;
    return super.close();
  }

  String? _buildCoordinatorTradingHint({
    required Environment environment,
    required Map<String, dynamic>? readiness,
    required bool readinessFailed,
  }) {
    final lines = <String>[];
    if (!ApiServiceConstants.dlcCoordinatorPartnerTokenConfigured) {
      lines.add(
        'Set DLC_COORDINATOR_PARTNER_TOKEN for trading; without it the coordinator may reject orders with 403.',
      );
    }
    if (readinessFailed) {
      lines.add('Could not read coordinator readiness (network or URL).');
    } else if (readiness != null) {
      final node = readiness['bitcoin_node'];
      final el = readiness['electrumx'];
      final nodeOk = node is Map<String, dynamic> && node['ok'] == true;
      final elOk = el is Map<String, dynamic> && el['ok'] == true;
      if (!nodeOk || !elOk) {
        lines.add(
          'Coordinator dependencies are not all healthy (Bitcoin node / ElectrumX).',
        );
      }
      final blockers = readiness['blockers'];
      if (blockers is List && blockers.isNotEmpty) {
        lines.add('Blockers: ${blockers.map((e) => e.toString()).join('; ')}');
      }
      final isRegtest = readiness['is_regtest'] == true;
      if (!environment.isTestnet && isRegtest) {
        lines.add(
          'Coordinator reports regtest while this app environment is mainnet.',
        );
      }
      final bitcoinNode = readiness['bitcoin_node'];
      final nodeDetails = bitcoinNode is Map<String, dynamic>
          ? bitcoinNode['details']
          : null;
      final chain = nodeDetails is Map<String, dynamic>
          ? nodeDetails['chain']?.toString().toLowerCase()
          : null;
      final electrumDetails = el is Map<String, dynamic> ? el['details'] : null;
      final providerNetwork = electrumDetails is Map<String, dynamic>
          ? electrumDetails['provider_network']?.toString().toLowerCase()
          : null;
      final coordinatorLooksTestnet =
          isRegtest ||
          chain == 'test' ||
          chain == 'testnet' ||
          providerNetwork == 'test' ||
          providerNetwork == 'testnet';
      if (environment.isTestnet && !coordinatorLooksTestnet) {
        lines.add(
          'Coordinator does not report testnet/testnet3 while this app environment is testnet.',
        );
      }
      if (!environment.isTestnet && coordinatorLooksTestnet) {
        lines.add(
          'Coordinator is running on testnet/testnet3; switch the app environment to testnet before trading.',
        );
      }
    }
    if (lines.isEmpty) return null;
    return lines.join('\n');
  }
}
