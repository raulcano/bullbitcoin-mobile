import 'dart:async';

import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bb_mobile/features/dlc/data/dlc_repository.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_instrument_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_dlc_detail_sync_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_negotiation_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_in_flight.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_system_readiness.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_wallet_pnl_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_wallet_sync_utils.dart';
import 'package:bb_mobile/features/dlc/presentation/dlc_state.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class DlcCubit extends Cubit<DlcState> {
  final DlcRepository _repository;
  Timer? _backgroundPollTimer;
  bool _pollInFlight = false;
  bool _negotiationInFlight = false;

  /// Bumped on wallet activate/switch so in-flight async work cannot apply stale orders.
  int _walletSessionGeneration = 0;

  DlcCubit({required DlcRepository repository})
    : _repository = repository,
      super(DlcState.initial());

  void _beginWalletSessionTransition() {
    _walletSessionGeneration++;
    _backgroundPollTimer?.cancel();
    _backgroundPollTimer = null;
  }

  /// True when a newer wallet activate/switch superseded this async work.
  bool _isStaleWalletSessionGeneration(int session) {
    if (isClosed) return true;
    return session != _walletSessionGeneration;
  }

  /// Generation + active auth must match (safe only after commit has emitted).
  bool _isStaleWalletSessionForWallet(int session, String walletOriginId) {
    if (_isStaleWalletSessionGeneration(session)) return true;
    return state.auth?.walletOriginId != walletOriginId;
  }

  Future<int?> _resolveWalletPnlSats({
    required Map<String, dynamic>? balances,
    required List<DlcOrderSummary> orders,
    double? btcUsdSpotPrice,
  }) async {
    final fromCoordinator = dlcWalletPnlSatsFromCoordinatorPayload(balances);
    if (fromCoordinator != null) return fromCoordinator;
    if (orders.isEmpty) return 0;
    double? spot = btcUsdSpotPrice;
    if (spot == null) {
      try {
        spot = await _repository.getBtcUsdSpotPrice();
      } catch (_) {
        return null;
      }
    }
    return _repository.estimateWalletPnlSats(
      orders: orders,
      btcUsdSpotUsd: spot,
    );
  }

  Future<void> load() async {
    if (state.auth != null) {
      await _reloadActiveWalletData();
      return;
    }
    await _loadCatalog();
  }

  /// Clears the global info/error banners (tab change, dismiss, refresh).
  void clearTransientMessages() {
    if (state.infoMessage == null && state.errorMessage == null) return;
    emit(state.copyWith(clearInfo: true, clearError: true));
  }

  /// Pull-to-refresh: only reload data relevant to the visible tab.
  Future<void> refreshCurrentTab() async {
    clearTransientMessages();
    switch (state.selectedTabIndex) {
      case 1:
        return refreshOrderbookTab();
      case 2:
        return refreshOrdersTab();
      case 3:
        return refreshSimulateTab();
      case 0:
      default:
        return refreshOverviewTab();
    }
  }

  /// Overview: wallet UTXO sync and balances (orders refresh only if sync cancels them).
  Future<void> refreshOverviewTab() async {
    if (state.auth == null) {
      await _loadCatalog();
      return;
    }
    try {
      var orders = state.orders;
      String? utxoSyncInfo;
      Map<String, dynamic>? balances;
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
      if (isClosed) return;
      final walletPnlSats = await _resolveWalletPnlSats(
        balances: balances,
        orders: orders,
        btcUsdSpotPrice: state.btcUsdSpotPrice,
      );
      if (isClosed) return;
      emit(
        state.copyWith(
          orders: orders,
          totalBalanceSat: (balances?['total_balance'] as num?)?.toInt(),
          availableBalanceSat: (balances?['available_balance'] as num?)?.toInt(),
          reservedBalanceSat: (balances?['reserved_balance'] as num?)?.toInt(),
          walletPnlSats: walletPnlSats,
          infoMessage: utxoSyncInfo,
          clearInfo: utxoSyncInfo == null,
          clearError: true,
        ),
      );
      _configureBackgroundPolling(orders);
    } catch (e) {
      if (!isClosed) {
        emit(state.copyWith(errorMessage: 'Failed to refresh wallet: $e'));
      }
    }
  }

  /// My orders: coordinator order list and in-flight phases only.
  Future<void> refreshOrdersTab() async {
    if (state.auth == null) return;
    try {
      final orders = await _ordersFromCoordinatorPreservingLocal();
      if (isClosed) return;
      emit(
        state.copyWith(
          orders: orders,
          clearInfo: true,
          clearError: true,
        ),
      );
      _configureBackgroundPolling(orders);
      if (await _repository.hasOrdersNeedingNegotiation()) {
        unawaited(_runNegotiationWorker(showProcessing: false));
      }
    } catch (e) {
      if (!isClosed) {
        emit(state.copyWith(errorMessage: 'Failed to refresh orders: $e'));
      }
    }
  }

  /// Simulate tab has no server-backed list to refresh.
  Future<void> refreshSimulateTab() async {}

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
      final strikeOrderbooks = selectedInstrument == null
          ? <DlcStrikeOrderbookSnapshot>[]
          : await _fetchStrikeOrderbooks(
              instrumentId: selectedInstrument,
              strikePrices: strikes.suggestions,
            );
      final legacyBooks = _legacyBooksForStrike(
        strikeOrderbooks,
        selectedStrike,
      );
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
          orderbookBids: legacyBooks.bids,
          orderbookAsks: legacyBooks.asks,
          strikeOrderbooks: strikeOrderbooks,
          orderbookRefreshing: false,
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
          orderbookRefreshing: false,
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
      final strikeOrderbooks = selectedInstrument == null
          ? <DlcStrikeOrderbookSnapshot>[]
          : await _fetchStrikeOrderbooks(
              instrumentId: selectedInstrument,
              strikePrices: strikes.suggestions,
            );
      final legacyBooks = _legacyBooksForStrike(
        strikeOrderbooks,
        selectedStrike,
      );
      final walletPnlSats = await _resolveWalletPnlSats(
        balances: balances,
        orders: orders,
        btcUsdSpotPrice: strikes.spotPrice,
      );
      if (isClosed) return;
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
          walletPnlSats: walletPnlSats,
          orderbookBids: legacyBooks.bids,
          orderbookAsks: legacyBooks.asks,
          strikeOrderbooks: strikeOrderbooks,
          orderbookRefreshing: false,
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
    _beginWalletSessionTransition();
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
    _beginWalletSessionTransition();
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
    final session = _walletSessionGeneration;
    _repository.clearDlcDetailCache();
    final validation = await _repository.validateAndLoadWalletAuths();
    final auth = validation.activeAuth;
    final registeredWalletAuths = await _repository.getAllWalletAuths();
    final orders = auth == null
        ? <DlcOrderSummary>[]
        : await _ordersFromCoordinatorPreservingLocal(
            fetchDlcDetails: false,
            preserveUiOrders: false,
            walletSession: session,
          );

    if (_isStaleWalletSessionGeneration(session)) return;

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
        clearWalletPnlSats: true,
        orderbookBids: const [],
        orderbookAsks: const [],
        strikeOrderbooks: const [],
        infoMessage: infoMessage,
      ),
    );
    _configureBackgroundPolling(orders);
    if (auth != null) {
      unawaited(
        _hydrateActiveWalletInBackground(
          walletSession: session,
          walletOriginId: auth.walletOriginId,
        ),
      );
    }
  }

  /// Refreshes balances, orderbook, and strikes after wallet switch (UTXO sync is slowest).
  Future<void> _hydrateActiveWalletInBackground({
    required int walletSession,
    required String walletOriginId,
  }) async {
    if (_isStaleWalletSessionForWallet(walletSession, walletOriginId)) return;

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
    final instrumentId = state.selectedInstrumentId;
    final strikeOrderbooks = instrumentId == null
        ? <DlcStrikeOrderbookSnapshot>[]
        : await _fetchStrikeOrderbooks(
            instrumentId: instrumentId,
            strikePrices: strikes.suggestions,
          );
    final legacyBooks = _legacyBooksForStrike(strikeOrderbooks, selectedStrike);

    if (_isStaleWalletSessionForWallet(walletSession, walletOriginId)) return;

    if (!isClosed) {
      emit(
        state.copyWith(
          orders: state.orders,
          totalBalanceSat: (balances?['total_balance'] as num?)?.toInt(),
          availableBalanceSat: (balances?['available_balance'] as num?)?.toInt(),
          reservedBalanceSat: (balances?['reserved_balance'] as num?)?.toInt(),
          orderbookBids: legacyBooks.bids,
          orderbookAsks: legacyBooks.asks,
          strikeOrderbooks: strikeOrderbooks,
          orderbookRefreshing: false,
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
        orders = await _ordersFromCoordinatorPreservingLocal(
          walletSession: walletSession,
        );
      }
    } catch (e) {
      try {
        balances = await _repository.getWalletBalances();
      } catch (_) {
        balances = null;
      }
      utxoSyncInfo = 'Could not sync wallet UTXOs with the coordinator: $e';
    }

    if (_isStaleWalletSessionForWallet(walletSession, walletOriginId)) return;

    if (!isClosed) {
      final walletPnlSats = await _resolveWalletPnlSats(
        balances: balances,
        orders: orders,
        btcUsdSpotPrice: state.btcUsdSpotPrice,
      );
      if (_isStaleWalletSessionForWallet(walletSession, walletOriginId)) return;
      emit(
        state.copyWith(
          orders: orders,
          totalBalanceSat: (balances?['total_balance'] as num?)?.toInt(),
          availableBalanceSat: (balances?['available_balance'] as num?)?.toInt(),
          reservedBalanceSat: (balances?['reserved_balance'] as num?)?.toInt(),
          walletPnlSats: walletPnlSats,
          infoMessage: utxoSyncInfo,
          clearInfo: utxoSyncInfo == null,
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
    // ignore: discarded_futures
    selectOptionInstrumentAndStrike(
      optionType: optionType,
      instrumentId: nextId,
      strikePrice: state.strikePrice,
    );
  }

  /// Orderbook: instruments catalog, strike suggestions, and open book per strike.
  Future<void> refreshOrderbookTab() async {
    emit(
      state.copyWith(
        orderbookRefreshing: true,
        clearInfo: true,
        clearError: true,
      ),
    );
    try {
      await _refreshOrderbookCatalog();
    } catch (e) {
      if (!isClosed) {
        emit(
          state.copyWith(
            orderbookRefreshing: false,
            errorMessage: 'Failed to refresh orderbook: $e',
          ),
        );
      }
    }
  }

  /// Instruments + BTC/USD strikes + per-strike open orders (no wallet UTXO sync).
  Future<void> _refreshOrderbookCatalog() async {
    final instruments = await _repository.listInstruments();
    final strikes = await _loadSuggestedStrikes();
    final filtered = instruments
        .where((i) => dlcInstrumentMatchesOptionType(i, state.optionType))
        .toList();
    var selectedId = state.selectedInstrumentId;
    if (selectedId == null ||
        !filtered.any((i) => dlcInstrumentId(i) == selectedId)) {
      selectedId = filtered.isEmpty ? null : dlcInstrumentId(filtered.first);
    }
    final selectedStrike = _selectStrike(
      current: state.strikePrice,
      suggestions: strikes.suggestions,
    );
    final strikeOrderbooks = selectedId == null
        ? <DlcStrikeOrderbookSnapshot>[]
        : await _fetchStrikeOrderbooks(
            instrumentId: selectedId,
            strikePrices: strikes.suggestions,
          );
    final legacyBooks = _legacyBooksForStrike(strikeOrderbooks, selectedStrike);
    if (isClosed) return;
    emit(
      state.copyWith(
        instruments: instruments,
        clearSelectedInstrument: selectedId == null,
        selectedInstrumentId: selectedId,
        strikePrice: selectedStrike,
        clearStrikePrice: selectedStrike == null,
        suggestedStrikePrices: strikes.suggestions,
        btcUsdSpotPrice: strikes.spotPrice,
        strikePriceError: strikes.error,
        clearStrikePriceError: strikes.error == null,
        strikeOrderbooks: strikeOrderbooks,
        orderbookBids: legacyBooks.bids,
        orderbookAsks: legacyBooks.asks,
        orderbookRefreshing: false,
      ),
    );
  }

  /// Refetches instruments from the coordinator and refreshes strike orderbooks.
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
      final strikeOrderbooks = selectedId == null
          ? <DlcStrikeOrderbookSnapshot>[]
          : await _fetchStrikeOrderbooks(
              instrumentId: selectedId,
              strikePrices: state.suggestedStrikePrices,
            );
      final legacyBooks = _legacyBooksForStrike(
        strikeOrderbooks,
        state.strikePrice,
      );
      emit(
        state.copyWith(
          loading: false,
          instruments: instruments,
          clearSelectedInstrument: selectedId == null,
          selectedInstrumentId: selectedId,
          orderbookBids: legacyBooks.bids,
          orderbookAsks: legacyBooks.asks,
          strikeOrderbooks: strikeOrderbooks,
          orderbookRefreshing: false,
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(
          loading: false,
          orderbookRefreshing: false,
          errorMessage: 'Failed to refresh instruments: $e',
        ),
      );
    }
  }

  void setTab(int index) {
    emit(
      state.copyWith(
        selectedTabIndex: index,
        clearInfo: true,
        clearError: true,
      ),
    );
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
    emit(state.copyWith(price: sats, clearError: true));
  }

  void setStrikePrice(double? strikePrice) {
    final legacyBooks = _legacyBooksForStrike(
      state.strikeOrderbooks,
      strikePrice,
    );
    emit(
      state.copyWith(
        strikePrice: strikePrice,
        clearStrikePrice: strikePrice == null,
        orderbookBids: legacyBooks.bids,
        orderbookAsks: legacyBooks.asks,
      ),
    );
  }

  void applyCreateOrderFromOrderbookDepth({
    required double strikePrice,
    required bool isAskRow,
    required double quantity,
    required int? premiumPerContractSats,
  }) {
    final snapshot = _strikeSnapshot(strikePrice);
    emit(
      state.copyWith(
        strikePrice: strikePrice,
        clearStrikePrice: false,
        orderbookBids: snapshot?.bids ?? const [],
        orderbookAsks: snapshot?.asks ?? const [],
        createOrderMatchIntent: true,
        side: isAskRow ? DlcOrderSide.buy : DlcOrderSide.sell,
        quantity: quantity,
        price: premiumPerContractSats?.toDouble() ?? state.price,
        clearError: true,
      ),
    );
  }

  void selectInstrumentAndStrike({
    required String? instrumentId,
    required double? strikePrice,
  }) {
    // ignore: discarded_futures
    selectOptionInstrumentAndStrike(
      optionType: state.optionType,
      instrumentId: instrumentId,
      strikePrice: strikePrice,
    );
  }

  Future<void> selectOptionInstrumentAndStrike({
    required DlcOptionType optionType,
    required String? instrumentId,
    required double? strikePrice,
  }) async {
    final instrumentChanged = instrumentId != state.selectedInstrumentId;
    final optionTypeChanged = optionType != state.optionType;
    final needsMarketLoad =
        instrumentId != null && (instrumentChanged || optionTypeChanged);

    emit(
      state.copyWith(
        optionType: optionType,
        selectedInstrumentId: instrumentId,
        clearSelectedInstrument: instrumentId == null,
        strikePrice: strikePrice,
        clearStrikePrice: strikePrice == null,
        clearError: true,
        orderbookRefreshing: needsMarketLoad,
        strikeOrderbooks: instrumentChanged ? const [] : state.strikeOrderbooks,
        orderbookBids: instrumentChanged ? const [] : state.orderbookBids,
        orderbookAsks: instrumentChanged ? const [] : state.orderbookAsks,
      ),
    );

    if (instrumentId == null) {
      emit(
        state.copyWith(
          strikeOrderbooks: const [],
          orderbookBids: const [],
          orderbookAsks: const [],
          orderbookRefreshing: false,
        ),
      );
      return;
    }

    if (!needsMarketLoad) {
      if (strikePrice != null) {
        setStrikePrice(strikePrice);
      }
      return;
    }

    try {
      await _reloadInstrumentMarketData();
    } catch (e) {
      if (!isClosed) {
        emit(
          state.copyWith(
            orderbookRefreshing: false,
            errorMessage: 'Failed to load instrument: $e',
          ),
        );
      }
    }
  }

  Future<void> refreshStrikePrices() async {
    if (state.selectedInstrumentId == null) return;
    emit(state.copyWith(orderbookRefreshing: true, clearError: true));
    try {
      await _reloadInstrumentMarketData();
    } catch (e) {
      if (!isClosed) {
        emit(
          state.copyWith(
            orderbookRefreshing: false,
            strikePriceError: 'Could not refresh BTC/USD strike suggestions: $e',
          ),
        );
      }
    }
  }

  /// Strike suggestions + per-strike orderbooks for the selected template instrument.
  Future<void> _reloadInstrumentMarketData() async {
    final strikes = await _loadSuggestedStrikes();
    final selectedStrike = _selectStrike(
      current: state.strikePrice,
      suggestions: strikes.suggestions,
    );
    final instrumentId = state.selectedInstrumentId;
    if (instrumentId == null) {
      if (!isClosed) {
        emit(state.copyWith(orderbookRefreshing: false));
      }
      return;
    }
    final strikeOrderbooks = await _fetchStrikeOrderbooks(
      instrumentId: instrumentId,
      strikePrices: strikes.suggestions,
    );
    if (isClosed) return;
    final legacyBooks = _legacyBooksForStrike(strikeOrderbooks, selectedStrike);
    emit(
      state.copyWith(
        suggestedStrikePrices: strikes.suggestions,
        strikePrice: selectedStrike,
        btcUsdSpotPrice: strikes.spotPrice,
        strikePriceError: strikes.error,
        clearStrikePriceError: strikes.error == null,
        strikeOrderbooks: strikeOrderbooks,
        orderbookBids: legacyBooks.bids,
        orderbookAsks: legacyBooks.asks,
        orderbookRefreshing: false,
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
      emit(state.copyWith(errorMessage: _friendlyCreateOrderError(e)));
    }
  }

  /// Maps a coordinator / wallet error to a user-facing message for the
  /// create-order flow. Used by both the synchronous validation catch and
  /// the unawaited background completion catch so the same heuristics apply
  /// regardless of where the failure originated.
  String _friendlyCreateOrderError(Object e) {
    final message = e.toString();
    final lower = message.toLowerCase();
    final notEnoughBalance =
        lower.contains('insufficient available balance') ||
        lower.contains('insufficient balance') ||
        lower.contains('not enough balance') ||
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
    if (partner403) {
      return 'Coordinator rejected the request (403). Check DLC_COORDINATOR_PARTNER_TOKEN and coordinator configuration.';
    }
    if (wallet401) {
      return 'DLC wallet token is invalid or expired. Refresh or re-register this wallet.';
    }
    if (instrument404) {
      return 'Selected instrument was not found. Refresh instruments and choose again.';
    }
    if (strikeRequired) {
      return 'Select a strike price greater than 0 before creating this order.';
    }
    if (quantityTooSmall) {
      return 'Order quantity must be positive.';
    }
    if (negativePremium) {
      return 'Premium per contract cannot be negative.';
    }
    if (notEnoughBalance) {
      // The coordinator-visible balance can lag the on-chain wallet view for
      // a few seconds after a recent match (its reserved-balance accounting
      // still holds the freshly-matched order). Phrase the message so users
      // who clearly have funds know to retry shortly.
      return 'Coordinator reports insufficient available balance. UTXOs may '
          'still be reconciling after a recent match — wait a few seconds '
          'and try again, or reduce quantity / free funds.';
    }
    return 'Create order failed: $e';
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

  Future<List<DlcStrikeOrderbookSnapshot>> _fetchStrikeOrderbooks({
    required String instrumentId,
    required List<double> strikePrices,
  }) async {
    final strikes = dlcStrikesForOrderbook(
      templateInstrumentId: instrumentId,
      suggestedStrikePrices: strikePrices,
    );
    if (strikes.isEmpty) return const [];

    final snapshots = await Future.wait(
      strikes.map((strike) async {
        final resolvedId = _orderbookInstrumentId(instrumentId, strike);
        if (resolvedId == null) return null;
        try {
          final orderbook = await _repository.getOrderbook(resolvedId);
          final bids = (orderbook['bids'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
          final asks = (orderbook['asks'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
          return dlcBuildStrikeOrderbookSnapshot(
            strikePrice: strike,
            bids: bids,
            asks: asks,
          );
        } catch (_) {
          return dlcBuildStrikeOrderbookSnapshot(
            strikePrice: strike,
            bids: const [],
            asks: const [],
          );
        }
      }),
    );

    final resolved = snapshots.whereType<DlcStrikeOrderbookSnapshot>().toList()
      ..sort((a, b) => a.strikePrice.compareTo(b.strikePrice));
    return resolved;
  }

  DlcStrikeOrderbookSnapshot? _strikeSnapshot(double strikePrice) {
    for (final snapshot in state.strikeOrderbooks) {
      if (snapshot.strikePrice == strikePrice) return snapshot;
    }
    return null;
  }

  ({List<Map<String, dynamic>> bids, List<Map<String, dynamic>> asks})
  _legacyBooksForStrike(
    List<DlcStrikeOrderbookSnapshot> snapshots,
    double? strikePrice,
  ) {
    if (snapshots.isEmpty) {
      return (bids: const [], asks: const []);
    }
    DlcStrikeOrderbookSnapshot? selected;
    if (strikePrice != null) {
      for (final snapshot in snapshots) {
        if (snapshot.strikePrice == strikePrice) {
          selected = snapshot;
          break;
        }
      }
    }
    selected ??= snapshots.first;
    return (bids: selected.bids, asks: selected.asks);
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
    return orderNeedsBackgroundStatusPoll(order);
  }

  Future<void> _backgroundPollTick() async {
    if (_pollInFlight || isClosed || state.loading) {
      return;
    }
    final session = _walletSessionGeneration;
    final walletOriginId = state.auth?.walletOriginId;
    if (walletOriginId == null) return;

    _pollInFlight = true;
    try {
      if (state.auth != null &&
          !state.processingOrder &&
          !_negotiationInFlight &&
          await _repository.hasOrdersNeedingNegotiation()) {
        await _runNegotiationWorker(
          showProcessing: false,
          walletSession: session,
          walletOriginId: walletOriginId,
        );
        return;
      }
      final previousOrders = state.orders;
      final orders = await _ordersFromCoordinatorPreservingLocal(
        walletSession: session,
      );
      if (!_isStaleWalletSessionForWallet(session, walletOriginId)) {
        await _applyOrdersAndMaybeSyncUtxosAfterProjection(
          previousOrders: previousOrders,
          orders: orders,
        );
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
    int? walletSession,
    String? walletOriginId,
  }) async {
    if (_negotiationInFlight || isClosed || state.auth == null) {
      return;
    }
    final session = walletSession ?? _walletSessionGeneration;
    final originId = walletOriginId ?? state.auth!.walletOriginId;
    _negotiationInFlight = true;
    try {
      if (showProcessing && !state.processingOrder) {
        emit(state.copyWith(processingOrder: true, clearError: true));
      }
      final result = await _repository.runNegotiationPass(
        focusOrderId: focusOrderId,
      );
      if (_isStaleWalletSessionForWallet(session, originId)) return;

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
      if (_isStaleWalletSessionForWallet(session, originId)) return;

      final previousOrders = state.orders;
      if (showProcessing) {
        final info = _combineInfoMessages([
          negotiationInfo,
          if (benignErrors.isNotEmpty)
            'Taker accept will continue in the background.',
        ]);
        await _applyOrdersAndMaybeSyncUtxosAfterProjection(
          previousOrders: previousOrders,
          orders: ordersWithPhases,
          extraInfoMessage: info,
          processingOrder: false,
          errorMessage:
              fatalErrors.isEmpty ? null : fatalErrors.join(' '),
          clearError: fatalErrors.isEmpty,
          clearInfo: info == null,
        );
      } else {
        await _applyOrdersAndMaybeSyncUtxosAfterProjection(
          previousOrders: previousOrders,
          orders: ordersWithPhases,
        );
      }
      _configureBackgroundPolling(ordersWithPhases);
    } catch (e) {
      if (!_isStaleWalletSessionForWallet(session, originId) &&
          !isClosed &&
          showProcessing) {
        final benign = isBenignDlcNegotiationMessage(e.toString());
        emit(
          state.copyWith(
            processingOrder: false,
            infoMessage: benign
                ? 'Taker accept will continue in the background.'
                : null,
            clearInfo: !benign,
            errorMessage: benign ? null : 'DLC negotiation failed: $e',
            clearError: benign,
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

  Future<void> _applyOrdersAndMaybeSyncUtxosAfterProjection({
    required List<DlcOrderSummary> previousOrders,
    required List<DlcOrderSummary> orders,
    String? extraInfoMessage,
    bool? processingOrder,
    String? errorMessage,
    bool clearError = false,
    bool clearInfo = false,
  }) async {
    if (isClosed) return;

    var syncInfo = extraInfoMessage;
    DlcWalletSyncResult? sync;
    if (state.auth != null) {
      sync = await _repository.syncActiveWalletUtxosAfterCoordinatorProjection(
        currentOrders: orders,
        previousOrders: previousOrders,
      );
      final syncMessage = formatDlcWalletSyncInfoMessage(sync);
      if (syncMessage != null) {
        syncInfo = _combineInfoMessages([syncInfo, syncMessage]);
      }
    }

    if (isClosed) return;

    emit(
      state.copyWith(
        orders: orders,
        processingOrder: processingOrder,
        totalBalanceSat: sync?.totalBalanceSat ?? state.totalBalanceSat,
        availableBalanceSat: sync?.availableBalanceSat ?? state.availableBalanceSat,
        reservedBalanceSat: sync?.reservedBalanceSat ?? state.reservedBalanceSat,
        infoMessage: syncInfo,
        clearInfo: clearInfo && syncInfo == null,
        errorMessage: errorMessage,
        clearError: clearError,
      ),
    );

    if (sync != null && state.auth != null) {
      final walletPnlSats = await _resolveWalletPnlSats(
        balances: {
          'total_balance': sync.totalBalanceSat,
          'available_balance': sync.availableBalanceSat,
          'reserved_balance': sync.reservedBalanceSat,
        },
        orders: orders,
        btcUsdSpotPrice: state.btcUsdSpotPrice,
      );
      if (!isClosed && walletPnlSats != null) {
        emit(state.copyWith(walletPnlSats: walletPnlSats));
      }
    }
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
      final parsed = DlcSystemReadiness.tryParse(readiness);
      if (parsed == null) {
        lines.add('Coordinator readiness response was not recognized.');
      } else {
        if (!parsed.canTrade) {
          if (!parsed.isChainBackendOk) {
            final chainError = parsed.chainBackend.error?.trim();
            lines.add(
              chainError != null && chainError.isNotEmpty
                  ? 'Coordinator chain backend is unavailable: $chainError'
                  : 'Coordinator chain backend is unavailable.',
            );
          }
          if (!parsed.tradingReady) {
            lines.add('Coordinator reports trading is not ready.');
          }
        }
        if (parsed.blockers.isNotEmpty) {
          lines.add('Blockers: ${parsed.blockers.join('; ')}');
        }
        if (!environment.isTestnet && parsed.isRegtest) {
          lines.add(
            'Coordinator reports regtest while this app environment is mainnet.',
          );
        }
        final coordinatorLooksTestnet = dlcCoordinatorNetworkIsTestnet(
          network: parsed.network,
          isRegtest: parsed.isRegtest,
        );
        final networkLabel = parsed.network.isEmpty ? 'unknown' : parsed.network;
        if (environment.isTestnet && !coordinatorLooksTestnet) {
          lines.add(
            'Coordinator network is $networkLabel while this app environment is testnet.',
          );
        }
        if (!environment.isTestnet && coordinatorLooksTestnet) {
          lines.add(
            'Coordinator is on $networkLabel; switch the app environment to testnet before trading.',
          );
        }
      }
    }
    if (lines.isEmpty) return null;
    return lines.join('\n');
  }

  Future<List<DlcOrderSummary>> _ordersFromCoordinatorPreservingLocal({
    bool fetchDlcDetails = true,
    bool preserveUiOrders = true,
    int? walletSession,
  }) async {
    final session = walletSession ?? _walletSessionGeneration;
    final coordinatorOrders = await _repository.listOrders(
      fetchDlcDetails: fetchDlcDetails,
    );
    if (_isStaleWalletSessionGeneration(session)) {
      return applyResolvedInFlightPhases(coordinatorOrders);
    }
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

      final selectedInstrumentId = state.selectedInstrumentId;
      final strikeOrderbooks = selectedInstrumentId == null
          ? state.strikeOrderbooks
          : await _fetchStrikeOrderbooks(
              instrumentId: selectedInstrumentId,
              strikePrices: state.suggestedStrikePrices,
            );
      final legacyBooks = _legacyBooksForStrike(
        strikeOrderbooks,
        state.strikePrice,
      );

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
          orderbookBids: legacyBooks.bids,
          orderbookAsks: legacyBooks.asks,
          strikeOrderbooks: strikeOrderbooks,
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
      // The create call may have actually succeeded on the coordinator but a
      // follow-up network step (e.g. listOrders for reconcile, or the second
      // sync-utxos) raised. Look up the order by idempotency key before
      // surfacing an error so a successful create + immediate match (order
      // becoming "live") is not reported as "Create order failed".
      final reconciled =
          await _repository.tryReconcileCreatedOrderByDraft(draft);
      if (isClosed) return;
      if (reconciled != null) {
        final resolved = applyResolvedInFlightPhase(reconciled);
        final orders = applyResolvedInFlightPhases(
          _replaceOrderInList(state.orders, clientOrderId, resolved),
        );
        emit(
          state.copyWith(
            orders: orders,
            infoMessage: createOrderPlacedInfoMessage(
              matchIntent: resolved.pendingMatchAccept || matchIntent,
            ),
            clearError: true,
          ),
        );
        _configureBackgroundPolling(orders);
        if (needsDlcTakerAccept(resolved) || needsDlcNegotiation(resolved)) {
          unawaited(
            _runNegotiationWorker(
              focusOrderId: resolved.orderId,
              showProcessing: false,
            ),
          );
        }
        return;
      }

      // Reconcile could not confirm the order. If the failure was transient
      // (timeout / connection error) the order may still be in flight on the
      // coordinator — keep the optimistic placeholder so background polling
      // can replace it and inform the user that we are still verifying.
      final transient = isTransientDlcCoordinatorMessage(e.toString());
      if (transient) {
        emit(
          state.copyWith(
            infoMessage:
                'Network issue while creating order. Verifying status with the coordinator…',
            clearError: true,
          ),
        );
        _configureBackgroundPolling(state.orders);
        unawaited(_backgroundPollTick());
        return;
      }

      final orders = state.orders
          .where((order) => order.orderId != clientOrderId)
          .toList(growable: false);
      emit(
        state.copyWith(
          orders: orders,
          errorMessage: _friendlyCreateOrderError(e),
        ),
      );
      _configureBackgroundPolling(orders);
    }
  }
}
