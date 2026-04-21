import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';

class DlcState {
  final bool loading;
  final bool processingOrder;
  final DlcWalletAuth? auth;
  final List<Map<String, dynamic>> instruments;
  final List<DlcOrderSummary> orders;
  final String? selectedInstrumentId;
  final DlcOptionType optionType;
  final DlcOrderSide side;
  final double quantity;
  final double price;
  final String? infoMessage;
  final String? errorMessage;
  final int selectedTabIndex;
  final int? totalBalanceSat;
  final int? availableBalanceSat;
  final int? reservedBalanceSat;
  final List<Map<String, dynamic>> orderbookBids;
  final List<Map<String, dynamic>> orderbookAsks;

  const DlcState({
    required this.loading,
    required this.processingOrder,
    required this.auth,
    required this.instruments,
    required this.orders,
    required this.selectedInstrumentId,
    required this.optionType,
    required this.side,
    required this.quantity,
    required this.price,
    required this.infoMessage,
    required this.errorMessage,
    required this.selectedTabIndex,
    required this.totalBalanceSat,
    required this.availableBalanceSat,
    required this.reservedBalanceSat,
    required this.orderbookBids,
    required this.orderbookAsks,
  });

  factory DlcState.initial() => const DlcState(
    loading: false,
    processingOrder: false,
    auth: null,
    instruments: [],
    orders: [],
    selectedInstrumentId: null,
    optionType: DlcOptionType.call,
    side: DlcOrderSide.buy,
    quantity: 0.01,
    price: 0,
    infoMessage: null,
    errorMessage: null,
    selectedTabIndex: 0,
    totalBalanceSat: null,
    availableBalanceSat: null,
    reservedBalanceSat: null,
    orderbookBids: [],
    orderbookAsks: [],
  );

  DlcState copyWith({
    bool? loading,
    bool? processingOrder,
    DlcWalletAuth? auth,
    bool clearAuth = false,
    List<Map<String, dynamic>>? instruments,
    List<DlcOrderSummary>? orders,
    String? selectedInstrumentId,
    bool clearSelectedInstrument = false,
    DlcOptionType? optionType,
    DlcOrderSide? side,
    double? quantity,
    double? price,
    String? infoMessage,
    bool clearInfo = false,
    String? errorMessage,
    bool clearError = false,
    int? selectedTabIndex,
    int? totalBalanceSat,
    int? availableBalanceSat,
    int? reservedBalanceSat,
    List<Map<String, dynamic>>? orderbookBids,
    List<Map<String, dynamic>>? orderbookAsks,
  }) {
    return DlcState(
      loading: loading ?? this.loading,
      processingOrder: processingOrder ?? this.processingOrder,
      auth: clearAuth ? null : (auth ?? this.auth),
      instruments: instruments ?? this.instruments,
      orders: orders ?? this.orders,
      selectedInstrumentId: clearSelectedInstrument
          ? null
          : (selectedInstrumentId ?? this.selectedInstrumentId),
      optionType: optionType ?? this.optionType,
      side: side ?? this.side,
      quantity: quantity ?? this.quantity,
      price: price ?? this.price,
      infoMessage: clearInfo ? null : (infoMessage ?? this.infoMessage),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      selectedTabIndex: selectedTabIndex ?? this.selectedTabIndex,
      totalBalanceSat: totalBalanceSat ?? this.totalBalanceSat,
      availableBalanceSat: availableBalanceSat ?? this.availableBalanceSat,
      reservedBalanceSat: reservedBalanceSat ?? this.reservedBalanceSat,
      orderbookBids: orderbookBids ?? this.orderbookBids,
      orderbookAsks: orderbookAsks ?? this.orderbookAsks,
    );
  }
}
