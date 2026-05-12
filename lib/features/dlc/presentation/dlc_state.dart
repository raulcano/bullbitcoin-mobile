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
  final List<DlcWalletOption> availableWallets;
  final String? selectedRegistrationWalletOriginId;
  final List<DlcExpiredWalletInfo> expiredWallets;
  final List<DlcWalletAuth> registeredWalletAuths;
  final Map<String, dynamic>? coordinatorReadiness;
  final bool coordinatorReadinessFailed;
  final String? coordinatorTradingHint;

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
    required this.availableWallets,
    required this.selectedRegistrationWalletOriginId,
    required this.expiredWallets,
    required this.registeredWalletAuths,
    required this.coordinatorReadiness,
    required this.coordinatorReadinessFailed,
    required this.coordinatorTradingHint,
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
    quantity: 10000,
    price: 0,
    infoMessage: null,
    errorMessage: null,
    selectedTabIndex: 0,
    totalBalanceSat: null,
    availableBalanceSat: null,
    reservedBalanceSat: null,
    orderbookBids: [],
    orderbookAsks: [],
    availableWallets: [],
    selectedRegistrationWalletOriginId: null,
    expiredWallets: [],
    registeredWalletAuths: [],
    coordinatorReadiness: null,
    coordinatorReadinessFailed: false,
    coordinatorTradingHint: null,
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
    List<DlcWalletOption>? availableWallets,
    String? selectedRegistrationWalletOriginId,
    bool clearSelectedRegistrationWallet = false,
    List<DlcExpiredWalletInfo>? expiredWallets,
    List<DlcWalletAuth>? registeredWalletAuths,
    Map<String, dynamic>? coordinatorReadiness,
    bool clearCoordinatorReadiness = false,
    bool? coordinatorReadinessFailed,
    String? coordinatorTradingHint,
    bool clearCoordinatorTradingHint = false,
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
      availableWallets: availableWallets ?? this.availableWallets,
      selectedRegistrationWalletOriginId: clearSelectedRegistrationWallet
          ? null
          : (selectedRegistrationWalletOriginId ??
                this.selectedRegistrationWalletOriginId),
      expiredWallets: expiredWallets ?? this.expiredWallets,
      registeredWalletAuths:
          registeredWalletAuths ?? this.registeredWalletAuths,
      coordinatorReadiness: clearCoordinatorReadiness
          ? null
          : (coordinatorReadiness ?? this.coordinatorReadiness),
      coordinatorReadinessFailed:
          coordinatorReadinessFailed ?? this.coordinatorReadinessFailed,
      coordinatorTradingHint: clearCoordinatorTradingHint
          ? null
          : (coordinatorTradingHint ?? this.coordinatorTradingHint),
    );
  }
}
