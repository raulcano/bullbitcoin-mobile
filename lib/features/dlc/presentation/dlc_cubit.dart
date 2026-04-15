import 'package:bb_mobile/features/dlc/data/dlc_repository.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/presentation/dlc_state.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class DlcCubit extends Cubit<DlcState> {
  final DlcRepository _repository;

  DlcCubit({required DlcRepository repository})
    : _repository = repository,
      super(DlcState.initial());

  Future<void> load() async {
    emit(state.copyWith(loading: true, clearError: true, clearInfo: true));
    try {
      final auth = await _repository.getWalletAuth();
      final instruments = await _repository.listInstruments();
      final orders = auth == null
          ? <DlcOrderSummary>[]
          : await _repository.listOrders();
      final balances = auth == null ? null : await _repository.getWalletBalances();
      final selectedInstrument = instruments.isEmpty
          ? null
          : (instruments.first['instrument_id'] as String? ??
                instruments.first['id'] as String?);
      final orderbook = selectedInstrument == null
          ? <String, dynamic>{}
          : await _repository.getOrderbook(selectedInstrument);
      emit(
        state.copyWith(
          loading: false,
          auth: auth,
          instruments: instruments,
          orders: orders,
          selectedInstrumentId: selectedInstrument,
          totalBalanceSat: (balances?['total_balance'] as num?)?.toInt(),
          availableBalanceSat: (balances?['available_balance'] as num?)?.toInt(),
          reservedBalanceSat: (balances?['reserved_balance'] as num?)?.toInt(),
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
          errorMessage: 'Failed to load DLC data: $e',
        ),
      );
    }
  }

  Future<void> registerWallet() async {
    emit(state.copyWith(loading: true, clearError: true, clearInfo: true));
    try {
      final auth = await _repository.registerDefaultWallet();
      final orders = await _repository.listOrders();
      emit(
        state.copyWith(
          loading: false,
          auth: auth,
          orders: orders,
          infoMessage: 'Wallet registered successfully.',
        ),
      );
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

  void setOptionType(DlcOptionType optionType) {
    final filtered = state.instruments.where((instrument) {
      final id = (instrument['instrument_id'] ?? instrument['id'] ?? '')
          .toString()
          .toUpperCase();
      return id.contains(optionType.value);
    }).toList();
    emit(
      state.copyWith(
        optionType: optionType,
        selectedInstrumentId: filtered.isEmpty
            ? state.selectedInstrumentId
            : (filtered.first['instrument_id'] ?? filtered.first['id']).toString(),
        clearError: true,
      ),
    );
    if (filtered.isNotEmpty) {
      final instrumentId =
          (filtered.first['instrument_id'] ?? filtered.first['id']).toString();
      // ignore: discarded_futures
      _refreshOrderbook(instrumentId);
    }
  }

  void setTab(int index) {
    emit(state.copyWith(selectedTabIndex: index));
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
      await _repository.createOrder(draft);
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
          availableBalanceSat: (balances?['available_balance'] as num?)?.toInt(),
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
    } catch (e) {
      emit(
        state.copyWith(loading: false, errorMessage: 'Create order failed: $e'),
      );
    }
  }

  Future<void> fulfillOrder(String orderId) async {
    emit(
      state.copyWith(
        processingOrder: true,
        clearError: true,
        clearInfo: true,
      ),
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
          availableBalanceSat: (balances?['available_balance'] as num?)?.toInt(),
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
    } catch (e) {
      emit(
        state.copyWith(
          processingOrder: false,
          errorMessage: 'Order fulfill failed: $e',
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
}
