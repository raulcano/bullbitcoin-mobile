import 'dart:async';

import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bb_mobile/features/dlc/data/dlc_repository.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_instrument_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_negotiation_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_wallet_sync_utils.dart';
import 'package:bb_mobile/features/dlc/presentation/dlc_state.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class DlcCubit extends Cubit<DlcState> {
  final DlcRepository _repository;
  Timer? _backgroundPollTimer;
  bool _pollInFlight = false;
  bool _negotiationInFlight = false;

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
      var orders = auth == null
          ? <DlcOrderSummary>[]
          : await _repository.listOrders();
      Map<String, dynamic>? balances;
      String? utxoSyncInfo;
      if (auth != null) {
        try {
          final sync = await _repository.syncActiveWalletUtxos();
          balances = {
            'total_balance': sync.totalBalanceSat,
            'available_balance': sync.availableBalanceSat,
            'reserved_balance': sync.reservedBalanceSat,
          };
          utxoSyncInfo = formatDlcWalletSyncInfoMessage(sync);
          if (sync.hasCancelledOrders) {
            orders = await _repository.listOrders();
          }
        } catch (e) {
          balances = await _repository.getWalletBalances();
          utxoSyncInfo = 'Could not sync wallet UTXOs with the coordinator: $e';
        }
      }
      final filteredForBook = instruments
          .where((i) => dlcInstrumentMatchesOptionType(i, state.optionType))
          .toList();
      final selectedInstrument = filteredForBook.isEmpty
          ? null
          : dlcInstrumentId(filteredForBook.first);
      final strikes = await _loadSuggestedStrikes();
      final selectedStrike = _selectStrike(
        current: state.strikePrice,
        suggestions: strikes.suggestions,
      );
      final orderbookInstrument = _orderbookInstrumentId(
        selectedInstrument,
        selectedStrike,
      );
      final orderbook = orderbookInstrument == null
          ? <String, dynamic>{}
          : await _repository.getOrderbook(orderbookInstrument);
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
          suggestedStrikePrices: strikes.suggestions,
          strikePrice: selectedStrike,
          btcUsdSpotPrice: strikes.spotPrice,
          strikePriceError: strikes.error,
          clearStrikePriceError: strikes.error == null,
          infoMessage: _combineInfoMessages([sessionInfo, utxoSyncInfo]),
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
      _configureBackgroundPolling(orders);
      if (auth != null && await _repository.hasOrdersNeedingNegotiation()) {
        unawaited(_runNegotiationWorker(showProcessing: false));
      }
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
      _configureBackgroundPolling(orders);
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
    selectInstrumentAndStrike(
      instrumentId: instrumentId,
      strikePrice: state.strikePrice,
    );
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

  Future<void> activateWalletForDlc(String walletOriginId) async {
    emit(state.copyWith(loading: true, clearError: true, clearInfo: true));
    try {
      final alreadyRegistered = state.registeredWalletAuths.any(
        (auth) => auth.walletOriginId == walletOriginId,
      );
      if (alreadyRegistered) {
        await _repository.setActiveWalletOriginId(walletOriginId);
      } else {
        await _repository.registerWalletByOriginId(walletOriginId);
      }
      await load();
      emit(
        state.copyWith(
          loading: false,
          infoMessage: alreadyRegistered
              ? 'Active DLC wallet switched.'
              : 'Wallet registered and activated for DLC.',
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(
          loading: false,
          errorMessage: 'Failed to activate DLC wallet: $e',
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
      _refreshOrderbookForSelection(
        instrumentId: nextId,
        strikePrice: state.strikePrice,
      );
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
      final orderbookInstrument = _orderbookInstrumentId(
        selectedId,
        state.strikePrice,
      );
      final orderbook = orderbookInstrument == null
          ? <String, dynamic>{}
          : await _repository.getOrderbook(orderbookInstrument);
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
      _configureBackgroundPolling(state.orders);
    }
  }

  void setQuantity(String quantity) {
    final parsed = double.tryParse(quantity);
    emit(
      state.copyWith(
        quantity: parsed ?? state.quantity,
        errorMessage: parsed != null && parsed < 0.01
            ? 'Minimum order size is 0.01 contracts.'
            : null,
        clearError: parsed == null || parsed >= 0.01,
      ),
    );
  }

  void setPrice(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      emit(state.copyWith(clearError: true));
      return;
    }
    final asInt = int.tryParse(trimmed);
    double? sats;
    if (asInt != null) {
      if (asInt < 0) {
        emit(
          state.copyWith(
            errorMessage: 'Premium per contract cannot be negative.',
          ),
        );
        return;
      }
      sats = asInt.toDouble();
    } else {
      final asDouble = double.tryParse(trimmed);
      if (asDouble == null) {
        emit(state.copyWith(price: state.price, clearError: true));
        return;
      }
      if (asDouble < 0) {
        emit(
          state.copyWith(
            errorMessage: 'Premium per contract cannot be negative.',
          ),
        );
        return;
      }
      final rounded = asDouble.round();
      if ((asDouble - rounded).abs() > 1e-9) {
        emit(
          state.copyWith(
            price: state.price,
            errorMessage: 'Premium must be a whole number of satoshis.',
          ),
        );
        return;
      }
      sats = rounded.toDouble();
    }
    emit(state.copyWith(price: sats!, clearError: true));
  }

  void setStrikePrice(double? strikePrice) {
    selectInstrumentAndStrike(
      instrumentId: state.selectedInstrumentId,
      strikePrice: strikePrice,
    );
  }

  void selectInstrumentAndStrike({
    required String? instrumentId,
    required double? strikePrice,
  }) {
    selectOptionInstrumentAndStrike(
      optionType: state.optionType,
      instrumentId: instrumentId,
      strikePrice: strikePrice,
    );
  }

  void selectOptionInstrumentAndStrike({
    required DlcOptionType optionType,
    required String? instrumentId,
    required double? strikePrice,
  }) {
    emit(
      state.copyWith(
        optionType: optionType,
        selectedInstrumentId: instrumentId,
        clearSelectedInstrument: instrumentId == null,
        strikePrice: strikePrice,
        clearStrikePrice: strikePrice == null,
        clearError: true,
      ),
    );
    if (instrumentId != null) {
      // ignore: discarded_futures
      _refreshOrderbookForSelection(
        instrumentId: instrumentId,
        strikePrice: strikePrice,
      );
    }
  }

  Future<void> refreshStrikePrices() async {
    final strikes = await _loadSuggestedStrikes();
    emit(
      state.copyWith(
        suggestedStrikePrices: strikes.suggestions,
        strikePrice: _selectStrike(
          current: state.strikePrice,
          suggestions: strikes.suggestions,
        ),
        btcUsdSpotPrice: strikes.spotPrice,
        strikePriceError: strikes.error,
        clearStrikePriceError: strikes.error == null,
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
      if (state.quantity <= 0) {
        throw Exception('Order quantity must be positive.');
      }
      if (state.price < 0) {
        throw Exception('Premium per contract cannot be negative.');
      }

      final draft = DlcOrderDraft(
        instrumentId: state.selectedInstrumentId!,
        side: state.side,
        quantity: state.quantity,
        price: state.price,
        strikePrice: state.strikePrice,
        fundingPubkeyHex: '',
      );
      final createResult = await _repository.createOrder(draft);
      final created = createResult.order;
      final syncBeforeMessage = formatDlcWalletSyncInfoMessage(
        createResult.syncBefore,
      );
      var refreshWarning = false;
      var orders = [
        created,
        ...state.orders.where((order) => order.orderId != created.orderId),
      ];
      if (createResult.syncBefore.hasCancelledOrders) {
        try {
          orders = await _repository.listOrders();
        } catch (_) {
          refreshWarning = true;
        }
      }
      try {
        orders = await _repository.listOrders();
      } catch (_) {
        refreshWarning = true;
      }
      Map<String, dynamic>? balances;
      try {
        balances = await _repository.getWalletBalances();
      } catch (_) {
        refreshWarning = true;
      }
      final orderbookInstrument = _orderbookInstrumentId(
        state.selectedInstrumentId,
        state.strikePrice,
      );
      var orderbookBids = state.orderbookBids;
      var orderbookAsks = state.orderbookAsks;
      if (orderbookInstrument != null) {
        try {
          final orderbook = await _repository.getOrderbook(orderbookInstrument);
          orderbookBids = (orderbook['bids'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
          orderbookAsks = (orderbook['asks'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
        } catch (_) {
          refreshWarning = true;
        }
      }
      final successMessage = created.pendingMatchAccept
          ? 'Order created and matched. Taker accept is required.'
          : 'Order created.';
      final infoMessage = _combineInfoMessages([
        syncBeforeMessage,
        refreshWarning
            ? '$successMessage Latest data refresh failed; pull to refresh.'
            : successMessage,
      ]);
      emit(
        state.copyWith(
          loading: false,
          orders: orders,
          totalBalanceSat: (balances?['total_balance'] as num?)?.toInt(),
          availableBalanceSat: (balances?['available_balance'] as num?)
              ?.toInt(),
          reservedBalanceSat: (balances?['reserved_balance'] as num?)?.toInt(),
          orderbookBids: orderbookBids,
          orderbookAsks: orderbookAsks,
          infoMessage: infoMessage,
        ),
      );
      _configureBackgroundPolling(orders);
      if (needsDlcTakerAccept(created) || needsDlcNegotiation(created)) {
        await _runNegotiationWorker(
          focusOrderId: created.orderId,
          showProcessing: true,
        );
      }
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
      final wallet401 = lower.contains('401');
      final instrument404 = lower.contains('404');
      final quantityTooSmall =
          lower.contains('quantity must be positive') ||
          lower.contains('minimum order size') ||
          lower.contains('0.01 contracts');
      final negativePremium =
          lower.contains('premium per contract') && lower.contains('negative');
      emit(
        state.copyWith(
          loading: false,
          errorMessage: partner403
              ? 'Coordinator rejected the request (403). Check DLC_COORDINATOR_PARTNER_TOKEN and coordinator configuration.'
              : wallet401
              ? 'DLC wallet token is invalid or expired. Refresh or re-register this wallet.'
              : instrument404
              ? 'Selected instrument was not found. Refresh instruments and choose again.'
              : strikeRequired
              ? 'Select a strike price greater than 0 before creating this order.'
              : quantityTooSmall
              ? 'Order quantity must be positive.'
              : negativePremium
              ? 'Premium per contract cannot be negative.'
              : notEnoughBalance
              ? 'Insufficient available balance. Sync wallet UTXOs with the coordinator, reduce quantity, or free funds.'
              : 'Create order failed: $e',
        ),
      );
    }
  }

  Future<({double? spotPrice, List<double> suggestions, String? error})>
  _loadSuggestedStrikes() async {
    try {
      final spot = await _repository.getBtcUsdSpotPrice();
      return (
        spotPrice: spot,
        suggestions: _repository.buildSuggestedStrikePrices(spot),
        error: null,
      );
    } catch (e) {
      return (
        spotPrice: state.btcUsdSpotPrice,
        suggestions: state.suggestedStrikePrices,
        error: 'Could not refresh BTC/USD strike suggestions: $e',
      );
    }
  }

  double? _selectStrike({
    required double? current,
    required List<double> suggestions,
  }) {
    if (suggestions.isEmpty) return current;
    if (current != null && suggestions.contains(current)) return current;
    return suggestions[suggestions.length ~/ 2];
  }

  Future<void> cancelOpenOrder(String orderId) async {
    emit(
      state.copyWith(processingOrder: true, clearError: true, clearInfo: true),
    );
    try {
      final cancelResult = await _repository.cancelOrder(orderId);
      final orders = await _repository.listOrders();
      Map<String, dynamic>? balances;
      try {
        balances = await _repository.getWalletBalances();
      } catch (_) {}
      emit(
        state.copyWith(
          processingOrder: false,
          orders: orders,
          totalBalanceSat: (balances?['total_balance'] as num?)?.toInt(),
          availableBalanceSat: (balances?['available_balance'] as num?)
              ?.toInt(),
          reservedBalanceSat: (balances?['reserved_balance'] as num?)?.toInt(),
          infoMessage: _combineInfoMessages([
            formatDlcWalletSyncInfoMessage(cancelResult.syncAfter),
            cancelResult.removedBecauseNotFoundOnCoordinator
                ? 'Order was not on the coordinator and was removed from this device.'
                : 'Order cancelled.',
          ]),
        ),
      );
      _configureBackgroundPolling(orders);
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
      final orderbookInstrument = _orderbookInstrumentId(
        state.selectedInstrumentId,
        state.strikePrice,
      );
      final orderbook = orderbookInstrument == null
          ? <String, dynamic>{}
          : await _repository.getOrderbook(orderbookInstrument);
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
      _configureBackgroundPolling(orders);
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
      _configureBackgroundPolling(orders);
    } catch (e) {
      emit(
        state.copyWith(
          processingOrder: false,
          errorMessage: 'Order lifecycle processing failed: $e',
        ),
      );
    }
  }

  Future<void> _refreshOrderbookForSelection({
    required String instrumentId,
    required double? strikePrice,
  }) async {
    try {
      final resolvedInstrumentId = _orderbookInstrumentId(
        instrumentId,
        strikePrice,
      );
      if (resolvedInstrumentId == null) return;
      final orderbook = await _repository.getOrderbook(resolvedInstrumentId);
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

  String? _orderbookInstrumentId(String? instrumentId, double? strikePrice) {
    if (instrumentId == null) return null;
    return dlcInstrumentIdWithStrike(instrumentId, strikePrice);
  }

  void _configureBackgroundPolling(List<DlcOrderSummary> orders) {
    final shouldPoll =
        state.auth != null &&
        (ordersNeedDlcNegotiation(orders) ||
            orders.any(_shouldPollOrderStatus));
    if (shouldPoll) {
      _backgroundPollTimer ??= Timer.periodic(
        const Duration(seconds: 15),
        (_) => _backgroundPollTick(),
      );
    } else {
      _backgroundPollTimer?.cancel();
      _backgroundPollTimer = null;
    }
  }

  bool _shouldPollOrderStatus(DlcOrderSummary order) {
    if (needsDlcNegotiation(order)) return true;
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

  Future<void> _backgroundPollTick() async {
    if (_pollInFlight || isClosed || state.loading) {
      return;
    }
    _pollInFlight = true;
    try {
      if (state.auth != null &&
          !state.processingOrder &&
          !_negotiationInFlight &&
          await _repository.hasOrdersNeedingNegotiation()) {
        await _runNegotiationWorker(showProcessing: false);
        return;
      }
      final orders = await _repository.listOrders();
      if (!isClosed) {
        emit(state.copyWith(orders: orders));
        _configureBackgroundPolling(orders);
      }
    } catch (_) {
      // Keep polling in case the next tick succeeds.
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> _runNegotiationWorker({
    String? focusOrderId,
    bool showProcessing = true,
  }) async {
    if (_negotiationInFlight || isClosed || state.auth == null) {
      return;
    }
    _negotiationInFlight = true;
    try {
      if (showProcessing && !state.processingOrder) {
        emit(state.copyWith(processingOrder: true, clearError: true));
      }
      final result = await _repository.runNegotiationPass(
        focusOrderId: focusOrderId,
      );
      if (isClosed) return;

      final negotiationInfo = _formatNegotiationInfo(result);
      emit(
        state.copyWith(
          processingOrder: showProcessing ? false : state.processingOrder,
          orders: result.orders.isNotEmpty ? result.orders : state.orders,
          infoMessage: _combineInfoMessages([
            negotiationInfo,
            state.infoMessage,
          ]),
          errorMessage: result.errors.isEmpty
              ? state.errorMessage
              : _combineInfoMessages([
                  result.errors.join(' '),
                  state.errorMessage,
                ]),
        ),
      );
      _configureBackgroundPolling(
        result.orders.isNotEmpty ? result.orders : state.orders,
      );
    } catch (e) {
      if (!isClosed) {
        emit(
          state.copyWith(
            processingOrder: showProcessing ? false : state.processingOrder,
            errorMessage: 'DLC negotiation failed: $e',
          ),
        );
      }
    } finally {
      _negotiationInFlight = false;
    }
  }

  String? _formatNegotiationInfo(DlcNegotiationPassResult result) {
    if (!result.didWork && result.errors.isEmpty) return null;
    final parts = <String>[];
    for (final action in result.actions) {
      switch (action.kind) {
        case DlcNegotiationActionKind.takerAccept:
          parts.add('Submitted taker accept for order ${action.orderId}.');
        case DlcNegotiationActionKind.makerSign:
          parts.add(
            'Submitted maker sign for DLC ${action.dlcId ?? action.orderId}.',
          );
      }
    }
    if (result.errors.isNotEmpty) {
      parts.add('Negotiation issues: ${result.errors.join('; ')}');
    }
    return parts.isEmpty ? null : parts.join(' ');
  }

  @override
  Future<void> close() {
    _backgroundPollTimer?.cancel();
    _backgroundPollTimer = null;
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

  String? _combineInfoMessages(List<String?> parts) {
    final messages = parts
        .map((part) => part?.trim())
        .whereType<String>()
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (messages.isEmpty) return null;
    return messages.join(' ');
  }
}
