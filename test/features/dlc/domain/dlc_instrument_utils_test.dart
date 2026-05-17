import 'package:bb_mobile/features/dlc/domain/dlc_instrument_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dlcInstrumentMatchesOptionType', () {
    test('matches API type field call/put (lowercase)', () {
      expect(
        dlcInstrumentMatchesOptionType({
          'instrument_id': 'X',
          'type': 'call',
        }, DlcOptionType.call),
        true,
      );
      expect(
        dlcInstrumentMatchesOptionType({
          'instrument_id': 'X',
          'type': 'call',
        }, DlcOptionType.put),
        false,
      );
      expect(
        dlcInstrumentMatchesOptionType({
          'instrument_id': 'X',
          'type': 'put',
        }, DlcOptionType.put),
        true,
      );
    });

    test('falls back to instrument_id suffix -C / -P', () {
      expect(
        dlcInstrumentMatchesOptionType({
          'instrument_id': 'BTC-31DEC25-STRIKE-C',
        }, DlcOptionType.call),
        true,
      );
      expect(
        dlcInstrumentMatchesOptionType({
          'instrument_id': 'BTC-31DEC25-STRIKE-P',
        }, DlcOptionType.put),
        true,
      );
    });
  });

  group('dlcInstrumentLabel', () {
    test('includes oracle when present', () {
      expect(
        dlcInstrumentLabel({
          'instrument_id': 'BTC-A',
          'oracle_label': 'oracle_1',
        }),
        'BTC-A · oracle_1',
      );
    });
  });

  group('dlcInstrumentMetadata', () {
    test('parses underlying expiry strike and right from instrument id', () {
      final metadata = dlcInstrumentMetadata({
        'instrument_id': 'BTC-18MAR26-74100-C',
      });

      expect(metadata.underlying, 'BTC');
      expect(metadata.expiryToken, '18MAR26');
      expect(metadata.strike, '74100');
      expect(metadata.right, DlcOptionType.call);
    });

    test('uses API type when right suffix is not enough', () {
      final metadata = dlcInstrumentMetadata({
        'instrument_id': 'BTC-18MAR26-STRIKE',
        'type': 'put',
      });

      expect(metadata.strike, 'STRIKE');
      expect(metadata.right, DlcOptionType.put);
    });
  });

  group('dlcInstrumentIdWithStrike', () {
    test('replaces STRIKE placeholder with normalized strike token', () {
      expect(
        dlcInstrumentIdWithStrike('BTC-18MAR26-STRIKE-C', 74100),
        'BTC-18MAR26-74100-C',
      );
    });

    test('leaves non-template instruments unchanged', () {
      expect(
        dlcInstrumentIdWithStrike('BTC-18MAR26-74100-P', 80000),
        'BTC-18MAR26-74100-P',
      );
    });
  });

  group('dlcInstrumentById', () {
    test('returns map when id matches', () {
      final list = <Map<String, dynamic>>[
        {'instrument_id': 'A', 'type': 'call'},
        {'instrument_id': 'B', 'type': 'put'},
      ];
      expect(dlcInstrumentById(list, 'B')?['type'], 'put');
      expect(dlcInstrumentById(list, 'missing'), isNull);
      expect(dlcInstrumentById(list, null), isNull);
    });
  });
}
