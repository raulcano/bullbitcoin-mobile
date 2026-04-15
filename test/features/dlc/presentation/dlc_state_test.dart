import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/presentation/dlc_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DlcState', () {
    test('initial has expected defaults', () {
      final state = DlcState.initial();

      expect(state.loading, false);
      expect(state.processingOrder, false);
      expect(state.auth, isNull);
      expect(state.optionType, DlcOptionType.call);
      expect(state.side, DlcOrderSide.buy);
      expect(state.quantity, 0.01);
      expect(state.price, 0);
    });

    test('copyWith can clear info and error messages', () {
      final state = DlcState.initial().copyWith(
        infoMessage: 'info',
        errorMessage: 'error',
      );

      final cleared = state.copyWith(clearInfo: true, clearError: true);

      expect(cleared.infoMessage, isNull);
      expect(cleared.errorMessage, isNull);
    });
  });
}
