import 'package:bb_mobile/core/utils/constants.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApiServiceConstants DLC instruments', () {
    tearDown(() {
      dotenv.loadFromString(envString: '', isOptional: true);
    });

    test('dlcInstrumentsListPath excludes expired by default', () {
      dotenv.loadFromString(envString: '', isOptional: true);
      expect(ApiServiceConstants.dlcShowExpiredInstruments, false);
      expect(
        ApiServiceConstants.dlcInstrumentsListPath,
        '/instruments/non-expired',
      );
    });

    test('dlcInstrumentsListPath uses GET /instruments when env is true', () {
      dotenv.loadFromString(
        envString: 'DLC_SHOW_EXPIRED_INSTRUMENTS=true',
        isOptional: true,
      );
      expect(ApiServiceConstants.dlcShowExpiredInstruments, true);
      expect(ApiServiceConstants.dlcInstrumentsListPath, '/instruments');
    });

    test(
      'dlcInstrumentsListPath uses GET /instruments/non-expired by default',
      () {
        dotenv.loadFromString(envString: '', isOptional: true);
        expect(
          ApiServiceConstants.dlcInstrumentsListPath,
          '/instruments/non-expired',
        );
      },
    );
  });
}
