import 'dart:async';

import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bb_mobile/features/dlc/data/dlc_repository.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_instrument_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_negotiation_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_in_flight.dart';
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
    if (state.auth != null) {
      await _reloadActiveWalletData();
      return;
    }
    await _loadCatalog();
  }

  /// Coordinator catalog and wallet picker only — no active wallet session or UTXO sync.
  Future<void> _loadCatalog() async {
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
      final registeredWalletAuths = await _repository.getAllWalletAuths();
      final lastActiveOriginId = await _repository.getActiveWalletOriginId();
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
      final defaultWalletOriginId =
          lastActiveOriginId ??
          state.selectedRegistrationWalletOriginId ??
          (wallets.isEmpty ? null : wallets.first.walletOriginId);

      emit(
        state.copyWith(
          loading: false,
          clearAuth: true,
          orders: const [],
          instruments: instruments,
          clearSelectedInstrument: selectedInstrument == null,
          selectedInstrumentId: selectedInstrument,
          clearStrikePrice: true,
          strikePrice: selectedStrike,
          btcUsdSpotPrice: strikes.spotPrice,
          strikePriceError: strikes.error,
          clearStrikePriceError: strikes.error == null,
          totalBalanceSat: null,
          availableBalanceSat: null,
          reservedBalanceSat: null,
          orderbookBids: (orderbook['bids'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
          orderbookAsks: (orderbook['asks'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
          suggestedStrikePrices: strikes.suggestions,
          availableWallets: wallets,
          selectedRegistrationWalletOriginId: defaultWalletOriginId,
          registeredWalletAuths: registeredWalletAuths,
          coordinatorReadiness: readiness,
          coordinatorReadinessFailed: readinessFailed,
          coordinatorTradingHint: tradingHint,
        ),
      );
      _configureBackgroundPolling(const []);
    } catch (e) {
      emit(
        state.copyWith(
          loading: false,
          errorMessage: 'Failed to load DLC data: $e',
        ),
      );
    }
  }

  /// Full refresh while a wallet session is already active (pull-to-refresh).
  Future<void> _reloadActiveWalletData() async {
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
      if (auth == null) {
        emit(state.copyWith(loading: false, clearAuth: true));
        await _loadCatalog();
        return;
      }
      final sessionInfo = validation.expiredWallets.isNotEmpty
          ? 'Some registered DLC wallets expired and were archived below.'
          : null;
      var orders = await _ordersFromCoordinatorPreservingLocal();
      Map<String, dynamic>? balances;
      String? utxoSyncInfo;
      try {
        final sync = await _repository.syncActiveWalletUtxos();
        balances = {
          'total_balance': sync.totalBalanceSat,
          'available_balance': sync.availableBalanceSat,
          'reserved_balance': sync.reservedBalanceSat,
        };
        utxoSyncInfo = formatDlcWalletSyncInfoMessage(sync);
        if (sync.hasCancelledOrders) {
          orders = await _ordersFromCoordinatorPreservingLocal();
        }
      } catch (e) {
        balances = await _repository.getWalletBalances();
        utxoSyncInfo = 'Could not sync wallet UTXOs with the coordinator: $e';
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
          selectedRegistrationWalletOriginId: auth.walletOriginId,
          expiredWallets: validation.expiredWallets,
          registeredWalletAuths: registeredWalletAuths,
          coordinatorReadiness: readiness,
          coordinatorReadinessFailed: readinessFailed,
          coordinatorTradingHint: tradingHint,
        ),
      );
      _configureBackgroundPolling(orders);
      if (await _repository.hasOrdersNeedingNegotiation()) {
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
    final walletOriginId = state.selectedRegistrationWalletOriginId;
    if (walletOriginId == null) {
      emit(state.copyWith(errorMessage: 'No Bitcoin wallet selected'));
      return;
    }
    await activateWalletForDlc(walletOriginId);
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
    emit(
      state.copyWith(
        actionInProgress: true,
        orders: const [],
        clearError: true,
        clearInfo: true,
      ),
    );
    try {
      await _repository.setActiveWalletOriginId(walletOriginId);
      await _commitActiveWalletSession(
        infoMessage: 'Active DLC wallet switched.',
      );
    } catch (e) {
      emit(
        state.copyWith(
          actionInProgress: false,
          errorMessage: 'Failed to switch DLC wallet: $e',
        ),
      );
    }
  }

  Future<void> activateWalletForDlc(String walletOriginId) async {
    emit(
      state.copyWith(
        actionInProgress: true,
        orders: const [],
        clearError: true,
        clearInfo: true,
      ),
    );
    try {
      final alreadyRegistered = state.registeredWalletAuths.any(
        (auth) => auth.walletOriginId == walletOriginId,
      );
      if (alreadyRegistered) {
        await _repository.setActiveWalletOriginId(walletOriginId);
      } else {
        await _repository.registerWalletByOriginId(walletOriginId);
      }
      await _commitActiveWalletSession(
        infoMessage: alreadyRegistered
            ? 'Active DLC wallet switched.'
            : 'Wallet registered and activated for DLC.',
      );
    } catch (e) {
      emit(
        state.copyWith(
          actionInProgress: false,
          errorMessage: 'Failed to activate DLC wallet: $e',
        ),
      );
    }
  }

  /// Applies the new active wallet without reloading instruments, readiness, or UTXOs.
  Future<void> _commitActiveWalletSession({required String infoMessage}) async {
    final validation = await _repository.validateAndLoadWalletAuths();
    final auth = validation.activeAuth;
    final registeredWalletAuths = await _repository.getAllWalletAuths();
    final orders = auth == null
        ? <DlcOrderSummary>[]
        : await _ordersFromCoordinatorPreservingLocal(preserveUiOrders: false);

    emit(
      state.copyWith(
        actionInProgress: false,
        auth: auth,
        orders: orders,
        registeredWalletAuths: registeredWalletAuths,
        expiredWallets: validation.expiredWallets,
        totalBalanceSat: null,
        availableBalanceSat: null,
        reservedBalanceSat: null,
        orderbookBids: const [],
        orderbookAsks: const [],
        infoMessage: infoMessage,
      ),
    );
    _configureBackgroundPolling(orders);
    if (auth != null) {
      unawaited(_hydrateActiveWalletInBackground());
    }
  }

  /// Refreshes balances, orderbook, and strikes after wallet switch (UTXO sync is slowest).
  Future<void> _hydrateActiveWalletInBackground() async {
    if (isClosed || state.auth == null) return;

    Map<String, dynamic>? balances;
    try {
      balances = await _repository.getWalletBalances();
    } catch (_) {
      balances = null;
    }

    final strikes = await _loadSuggestedStrikes();
    final selectedStrike = _selectStrike(
      current: state.strikePrice,
      suggestions: strikes.suggestions,
    );
    final orderbookInstrument = _orderbookInstrumentId(
      state.selectedInstrumentId,
      selectedStrike,
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
        // Keep empty book until the next refresh succeeds.
      }
    }

    if (!isClosed) {
      emit(
        state.copyWith(
          orders: state.orders,
          totalBalanceSat: (balances?['total_balance'] as num?)?.toInt(),
          availableBalanceSat: (balances?['available_balance'] as num?)?.toInt(),
          reservedBalanceSat: (balances?['reserved_balance'] as num?)?.toInt(),
          orderbookBids: orderbookBids,
          orderbookAsks: orderbookAsks,
          suggestedStrikePrices: strikes.suggestions,
          strikePrice: selectedStrike,
          btcUsdSpotPrice: strikes.spotPrice,
          strikePriceError: strikes.error,
          clearStrikePriceError: strikes.error == null,
        ),
      );
    }

    var orders = state.orders;
    String? utxoSyncInfo;
    try {
      final sync = await _repository.syncActiveWalletUtxos();
      balances = {
        'total_balance': sync.totalBalanceSat,
        'available_balance': sync.availableBalanceSat,
        'reserved_balance': sync.reservedBalanceSat,
      };
      utxoSyncInfo = formatDlcWalletSyncInfoMessage(sync);
      if (sync.hasCancelledOrders) {
        orders = await _ordersFromCoordinatorPreservingLocal();
      }
    } catch (e) {
      try {
        balances = await _repository.getWalletBalances();
      } catch (_) {
        balances = null;
      }
      utxoSyncInfo = 'Could not sync wallet UTXOs with the coordinator: $e';
    }

    if (!isClosed) {
      emit(
        state.copyWith(
          orders: orders,
          totalBalanceSat: (balances?['total_balance'] as num?)?.toInt(),
          availableBalanceSat: (balances?['available_balance'] as num?)?.toInt(),
          reservedBalanceSat: (balances?['reserved_balance'] as num?)?.toInt(),
          infoMessage: _combineInfoMessages([utxoSyncInfo, state.infoMessage]),
        ),
      );
      _configureBackgroundPolling(orders);
      if (await _repository.hasOrdersNeedingNegotiation()) {
        unawaited(_runNegotiationWorker(showProcessing: false));
      }
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

  /// Refetches instruments from the coordinator and refreshes the orderbook.
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

  void setCreateOrderMatchIntent(bool value) {
    emit(state.copyWith(createOrderMatchIntent: value));
  }

  Future<void> createOrder() async {
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

      final matchIntent = state.createOrderMatchIntent;
      final draft = DlcOrderDraft(
        instrumentId: state.selectedInstrumentId!,
        side: state.side,
        quantity: state.quantity,
        price: state.price,
        strikePrice: state.strikePrice,
        fundingPubkeyHex: '',
      );
      final clientOrderId =
          '$dlcLocalPendingOrderIdPrefix${DateTime.now().millisecondsSinceEpoch}';
      final optimistic = _buildOptimisticOrder(
        draft: draft,
        clientOrderId: clientOrderId,
        matchIntent: matchIntent,
      );

      final nextOrders = [
        optimistic,
        ...state.orders.where((o) => o.orderId != clientOrderId),
      ];
      var orderbookBids = state.orderbookBids;
      var orderbookAsks = state.orderbookAsks;
      if (matchIntent) {
        final trimmed = optimisticTrimOrderbookForMatch(
          bids: orderbookBids,
          asks: orderbookAsks,
          draft: draft,
        );
        orderbookBids = trimmed.bids;
        orderbookAsks = trimmed.asks;
      }
      emit(
        state.copyWith(
          clearError: true,
          clearInfo: true,
          clearCreateOrderMatchIntent: true,
          selectedTabIndex: 2,
          orders: nextOrders,
          orderbookBids: orderbookBids,
          orderbookAsks: orderbookAsks,
          infoMessage: createOrderPlacedInfoMessage(matchIntent: matchIntent),
        ),
      );
      _configureBackgroundPolling(nextOrders);

      unawaited(
        _completeCreateOrderInBackground(
          draft: draft,
          clientOrderId: clientOrderId,
          matchIntent: matchIntent,
        ),
      );
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
      var orders = await _ordersFromCoordinatorPreservingLocal();
      if (cancelResult.removedBecauseNotFoundOnCoordinator) {
        orders = orders.where((order) => order.orderId != orderId).toList();
      }
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
      final orders = await _ordersFromCoordinatorPreservingLocal();
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
      final orders = await _ordersFromCoordinatorPreservingLocal();
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
        await _runNegotiationWorker(showProcessing: true);
        return;
      }
      final orders = await _ordersFromCoordinatorPreservingLocal();
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
    bool showProcessing = false,
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
      final fatalErrors = result.errors
          .where((error) => !isBenignDlcNegotiationMessage(error))
          .toList(growable: false);
      final benignErrors = result.errors
          .where(isBenignDlcNegotiationMessage)
          .toList(growable: false);
      final ordersWithPhases = applyResolvedInFlightPhases(
        result.orders.isNotEmpty
            ? mergeCoordinatorOrdersWithLocal(
                coordinatorOrders: result.orders,
                currentOrders: state.orders,
              )
            : state.orders,
      );
      emit(
        state.copyWith(
          processingOrder: showProcessing ? false : state.processingOrder,
          orders: ordersWithPhases,
          infoMessage: _combineInfoMessages([
            negotiationInfo,
            if (benignErrors.isNotEmpty)
              'Taker accept will continue in the background.',
            state.infoMessage,
          ]),
          errorMessage: fatalErrors.isEmpty
              ? state.errorMessage
              : _combineInfoMessages([
                  fatalErrors.join(' '),
                  state.errorMessage,
                ]),
        ),
      );
      _configureBackgroundPolling(ordersWithPhases);
    } catch (e) {
      if (!isClosed) {
        final benign = isBenignDlcNegotiationMessage(e.toString());
        emit(
          state.copyWith(
            processingOrder: showProcessing ? false : state.processingOrder,
            infoMessage: benign
                ? _combineInfoMessages([
                    'Taker accept will continue in the background.',
                    state.infoMessage,
                  ])
                : state.infoMessage,
            errorMessage: benign
                ? state.errorMessage
                : 'DLC negotiation failed: $e',
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

  Future<List<DlcOrderSummary>> _ordersFromCoordinatorPreservingLocal({
    bool preserveUiOrders = true,
  }) async {
    final coordinatorOrders = await _repository.listOrders();
    final merged = preserveUiOrders
        ? mergeCoordinatorOrdersWithLocal(
            coordinatorOrders: coordinatorOrders,
            currentOrders: state.orders,
          )
        : coordinatorOrders;
    return applyResolvedInFlightPhases(merged);
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

  DlcOrderSummary _buildOptimisticOrder({
    required DlcOrderDraft draft,
    required String clientOrderId,
    required bool matchIntent,
  }) {
    final instrumentId = draft.strikePrice == null
        ? draft.instrumentId
        : dlcInstrumentIdWithStrike(draft.instrumentId, draft.strikePrice);
    final phase = matchIntent
        ? DlcOrderInFlightPhase.takerSigningAccept
        : DlcOrderInFlightPhase.creatingOnCoordinator;
    return DlcOrderSummary(
      orderId: clientOrderId,
      dlcId: null,
      status: matchIntent ? 'pending_accept' : 'open',
      pendingMatchAccept: matchIntent,
      inFlightPhase: phase,
      matchedOrderId: null,
      matchedDlcId: null,
      isMaker: matchIntent ? false : true,
      matchRole: matchIntent ? 'taker' : 'maker',
      signRequired: null,
      dlcStatus: null,
      settlementType: null,
      confirmationStatus: null,
      instrumentId: instrumentId,
      side: draft.side.value,
      quantity: draft.quantity,
      price: draft.price,
      createdAt: DateTime.now().toUtc(),
      sideCollateralSat: null,
      partnerFeeSat: null,
      networkFeeSat: null,
      lastErrorReason: null,
      lastErrorMessage: null,
      oracleOutcomeValue: null,
      fundingTxid: null,
      closingTxid: null,
      refundTxid: null,
    );
  }

  List<DlcOrderSummary> _replaceOrderInList(
    List<DlcOrderSummary> orders,
    String previousOrderId,
    DlcOrderSummary replacement,
  ) {
    final updated = <DlcOrderSummary>[];
    var replaced = false;
    for (final order in orders) {
      if (order.orderId == previousOrderId) {
        if (!replaced) {
          updated.add(replacement);
          replaced = true;
        }
        continue;
      }
      if (order.orderId == replacement.orderId) continue;
      updated.add(order);
    }
    if (!replaced) {
      updated.insert(0, replacement);
    }
    return updated;
  }

  Future<void> _completeCreateOrderInBackground({
    required DlcOrderDraft draft,
    required String clientOrderId,
    required bool matchIntent,
  }) async {
    if (isClosed) return;
    try {
      final createResult = await _repository.createOrder(draft);
      if (isClosed) return;

      final created = applyResolvedInFlightPhase(createResult.order);
      final syncBeforeMessage = formatDlcWalletSyncInfoMessage(
        createResult.syncBefore,
      );

      var orders = applyResolvedInFlightPhases(
        _replaceOrderInList(state.orders, clientOrderId, created),
      );

      if (createResult.syncBefore.hasCancelledOrders) {
        try {
          orders = await _ordersFromCoordinatorPreservingLocal();
        } catch (_) {}
      }

      Map<String, dynamic>? balances;
      try {
        balances = await _repository.getWalletBalances();
      } catch (_) {}

      var orderbookBids = state.orderbookBids;
      var orderbookAsks = state.orderbookAsks;
      final orderbookInstrument = _orderbookInstrumentId(
        state.selectedInstrumentId,
        state.strikePrice,
      );
      if (orderbookInstrument != null) {
        try {
          final orderbook = await _repository.getOrderbook(orderbookInstrument);
          orderbookBids = (orderbook['bids'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
          orderbookAsks = (orderbook['asks'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
        } catch (_) {}
      }

      emit(
        state.copyWith(
          orders: orders,
          totalBalanceSat: (balances?['total_balance'] as num?)?.toInt() ??
              state.totalBalanceSat,
          availableBalanceSat:
              (balances?['available_balance'] as num?)?.toInt() ??
                  state.availableBalanceSat,
          reservedBalanceSat: (balances?['reserved_balance'] as num?)?.toInt() ??
              state.reservedBalanceSat,
          orderbookBids: orderbookBids,
          orderbookAsks: orderbookAsks,
          infoMessage: _combineInfoMessages([
            createOrderPlacedInfoMessage(
              matchIntent: created.pendingMatchAccept || matchIntent,
            ),
            syncBeforeMessage,
          ]),
        ),
      );
      _configureBackgroundPolling(orders);

      if (needsDlcTakerAccept(created) || needsDlcNegotiation(created)) {
        unawaited(
          _runNegotiationWorker(
            focusOrderId: created.orderId,
            showProcessing: false,
          ),
        );
      }

      if (!isClosed) {
        try {
          final refreshed = await _ordersFromCoordinatorPreservingLocal();
          emit(state.copyWith(orders: refreshed));
          _configureBackgroundPolling(refreshed);
        } catch (_) {}
      }
    } catch (e) {
      if (isClosed) return;
      final orders = state.orders
          .where((order) => order.orderId != clientOrderId)
          .toList(growable: false);
      emit(
        state.copyWith(
          orders: orders,
          errorMessage: 'Create order failed: $e',
        ),
      );
      _configureBackgroundPolling(orders);
    }
  }
}
