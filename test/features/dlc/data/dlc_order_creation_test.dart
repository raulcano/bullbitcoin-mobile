import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_mobile/core/entities/signer_entity.dart';
import 'package:bb_mobile/core/settings/data/settings_repository.dart';
import 'package:bb_mobile/core/settings/domain/repositories/settings_repository.dart'
    as domain;
import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/storage/data/datasources/key_value_storage/key_value_storage_datasource.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet_utxo.dart';
import 'package:bb_mobile/core/wallet/domain/usecases/get_wallet_utxos_usecase.dart';
import 'package:bb_mobile/features/dlc/data/dlc_api_datasource.dart';
import 'package:bb_mobile/features/dlc/data/dlc_auth_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_idempotency_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_negotiation_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_order_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_repository.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_local_signer.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockSettingsRepository extends Mock implements SettingsRepository {}

class _MockDomainSettingsRepository extends Mock
    implements domain.SettingsRepository {}

class _MockDlcApiDatasource extends Mock implements DlcApiDatasource {}

class _MockDlcLocalSigner extends Mock implements DlcLocalSigner {}

class _MockGetWalletUtxosUsecase extends Mock
    implements GetWalletUtxosUsecase {}

class _MemoryStorage implements KeyValueStorageDatasource<String> {
  final values = <String, String>{};

  @override
  Future<void> saveValue({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<String?> getValue(String key) async => values[key];

  @override
  Future<Map<String, String>> getAll() async => Map.of(values);

  @override
  Future<bool> hasValue(String key) async => values.containsKey(key);

  @override
  Future<void> deleteValue(String key) async => values.remove(key);

  @override
  Future<void> deleteAll() async => values.clear();
}

void main() {
  late _MemoryStorage storage;
  late _MockSettingsRepository settings;
  late _MockDlcApiDatasource datasource;
  late _MockDlcLocalSigner signer;
  late _MockGetWalletUtxosUsecase getWalletUtxosUsecase;
  late DlcAuthStorage authStorage;
  late DlcIdempotencyStorage idempotencyStorage;
  late DlcOrderStorage orderStorage;
  late DlcNegotiationStorage negotiationStorage;
  late DlcRepository repository;

  final auth = DlcWalletAuth(
    walletOriginId: 'wallet-origin',
    walletLabel: 'DLC wallet',
    walletXpub: 'xpub-test',
    walletId: 'wallet-123',
    walletToken: 'wallet-token',
    expiresAt: DateTime.utc(2099),
  );
  const validXpub =
      'xpub6CGi7b6gV4igg6sYbhYV6s6AfsuQKfXpu5Bp6f4Puxmtst8Y2cAdaJLYoDr2krV1QnxZZsTtSvsGCpz2oddkaxQ3YepUntPLuU89HhMM4Vp';
  final wallet = Wallet(
    origin: 'wallet-origin',
    label: 'DLC wallet',
    network: Network.bitcoinTestnet,
    isDefault: true,
    masterFingerprint: 'f23f9fd2',
    xpubFingerprint: 'f23f9fd2',
    scriptType: ScriptType.bip84,
    xpub: validXpub,
    externalPublicDescriptor: "wpkh([f23f9fd2/84'/1'/0']$validXpub/0/*)",
    internalPublicDescriptor: "wpkh([f23f9fd2/84'/1'/0']$validXpub/1/*)",
    signer: SignerEntity.local,
    signerDevice: null,
    balanceSat: BigInt.zero,
  );
  const funding = DlcFundingPubkey(
    pubkeyHex:
        '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
    derivationPath: "m/84'/1'/0'/0/0",
  );

  Map<String, dynamic> coordinatorSyncPayload() => {
    'total_balance': 100000,
    'available_balance': 100000,
    'reserved_balance': 0,
    'cancelled_orders': const [],
    'rejected_utxos': const [],
  };

  void mockCoordinatorUtxoSync() {
    when(
      () => datasource.createNonce(),
    ).thenAnswer((_) async => {'nonce': 'sync-nonce'});
    when(
      () => getWalletUtxosUsecase.execute(walletId: any(named: 'walletId')),
    ).thenAnswer((_) async => const []);
    when(
      () => signer.buildUtxoProofs(
        wallet: wallet,
        utxos: const [],
        nonce: 'sync-nonce',
      ),
    ).thenAnswer((_) async => const []);
    when(
      () => datasource.syncWalletUtxos(
        token: any(named: 'token'),
        walletId: any(named: 'walletId'),
        utxos: any(named: 'utxos'),
        nonce: any(named: 'nonce'),
      ),
    ).thenAnswer((_) async => coordinatorSyncPayload());
  }

  setUp(() async {
    storage = _MemoryStorage();
    settings = _MockSettingsRepository();
    datasource = _MockDlcApiDatasource();
    signer = _MockDlcLocalSigner();
    getWalletUtxosUsecase = _MockGetWalletUtxosUsecase();
    authStorage = DlcAuthStorage(secureStorage: storage);
    idempotencyStorage = DlcIdempotencyStorage(secureStorage: storage);
    orderStorage = DlcOrderStorage(secureStorage: storage);
    negotiationStorage = DlcNegotiationStorage(secureStorage: storage);
    repository = DlcRepository(
      settingsRepository: settings,
      datasource: datasource,
      authStorage: authStorage,
      idempotencyStorage: idempotencyStorage,
      orderStorage: orderStorage,
      negotiationStorage: negotiationStorage,
      localSigner: signer,
      getWalletUtxosUsecase: getWalletUtxosUsecase,
    );
    when(() => settings.fetch()).thenAnswer(
      (_) async => const SettingsEntity(
        environment: Environment.testnet,
        bitcoinUnit: BitcoinUnit.btc,
        currencyCode: 'USD',
      ),
    );
    when(
      () => signer.getBitcoinWalletByOriginId(
        environment: Environment.testnet,
        walletOriginId: auth.walletOriginId,
      ),
    ).thenAnswer((_) async => wallet);
    when(
      () => signer.registrationXpubForCoordinator(wallet: wallet),
    ).thenAnswer((_) async => wallet.xpub);
    when(
      () => signer.deriveFundingPubkey(wallet: wallet),
    ).thenAnswer((_) async => funding);
    when(() => datasource.listInstruments()).thenAnswer(
      (_) async => [
        {'instrument_id': 'BTC-18MAR26-74100-C'},
      ],
    );
    await authStorage.store(Environment.testnet, auth);
  });

  group('DlcRepository wallet switching', () {
    test('validation refresh preserves the selected active wallet', () async {
      final first = auth;
      final second = DlcWalletAuth(
        walletOriginId: 'wallet-origin-2',
        walletLabel: 'Second DLC wallet',
        walletXpub: 'xpub-test-2',
        walletId: 'wallet-456',
        walletToken: 'wallet-token-2',
        expiresAt: DateTime.utc(2099),
      );
      await authStorage.store(Environment.testnet, second);
      await authStorage.setActiveWalletOriginId(
        Environment.testnet,
        first.walletOriginId,
      );
      when(
        () => datasource.getWalletOrNullOnAuthFailure(
          token: first.walletToken,
          walletId: first.walletId,
        ),
      ).thenAnswer(
        (_) async => {
          'wallet_id': first.walletId,
          'expires_at': '2099-02-01T00:00:00Z',
        },
      );
      when(
        () => datasource.getWalletOrNullOnAuthFailure(
          token: second.walletToken,
          walletId: second.walletId,
        ),
      ).thenAnswer(
        (_) async => {
          'wallet_id': second.walletId,
          'expires_at': '2099-02-01T00:00:00Z',
        },
      );

      final validation = await repository.validateAndLoadWalletAuths();

      expect(validation.activeAuth?.walletOriginId, first.walletOriginId);
      expect(
        (await authStorage.get(Environment.testnet))?.walletOriginId,
        first.walletOriginId,
      );
    });
  });

  group('DlcRepository.registerWalletByOriginId', () {
    test(
      'sends local UTXO ownership proofs during wallet registration',
      () async {
        final utxos = [
          WalletUtxo.bitcoin(
            walletId: wallet.id,
            txId: 'txid-1',
            vout: 0,
            scriptPubkey: Uint8List.fromList([0, 20, ...List.filled(20, 1)]),
            amountSat: BigInt.from(100000),
            address: 'bcrt1qexample',
          ),
        ];
        final proofs = [
          {
            'txid': 'txid-1',
            'vout': 0,
            'signature': 'signature-hex',
            'public_key': funding.pubkeyHex,
          },
        ];
        when(
          () => datasource.createNonce(),
        ).thenAnswer((_) async => {'nonce': 'nonce-1'});
        when(
          () => signer.signXpubRegistrationProof(
            wallet: wallet,
            nonce: 'nonce-1',
          ),
        ).thenAnswer((_) async => 'xpub-signature');
        when(
          () => getWalletUtxosUsecase.execute(walletId: wallet.id),
        ).thenAnswer((_) async => utxos);
        when(
          () => signer.buildUtxoProofs(
            wallet: wallet,
            utxos: utxos,
            nonce: 'nonce-1',
          ),
        ).thenAnswer((_) async => proofs);
        when(
          () => datasource.registerWallet(
            xpub: any(named: 'xpub'),
            nonce: 'nonce-1',
            xpubSignature: 'xpub-signature',
            label: any(named: 'label'),
            utxos: any(named: 'utxos'),
          ),
        ).thenAnswer(
          (_) async => {
            'wallet_id': 'registered-wallet',
            'wallet_token': 'registered-token',
            'expires_at': '2099-01-01T00:00:00Z',
          },
        );
        await repository.registerWalletByOriginId(wallet.id);

        final capturedUtxos =
            verify(
                  () => datasource.registerWallet(
                    xpub: any(named: 'xpub'),
                    nonce: 'nonce-1',
                    xpubSignature: 'xpub-signature',
                    label: any(named: 'label'),
                    utxos: captureAny(named: 'utxos'),
                  ),
                ).captured.single
                as List<Map<String, dynamic>>;
        expect(capturedUtxos, proofs);
        expect(capturedUtxos.single.keys, isNot(contains('seed')));
        expect(capturedUtxos.single.keys, isNot(contains('xpriv')));
        expect(capturedUtxos.single.keys, isNot(contains('private_key')));
      },
    );
  });

  group('DlcRepository.createOrder', () {
    setUp(mockCoordinatorUtxoSync);

    test('posts canonical order body without private material', () async {
      when(
        () => datasource.createOrder(
          token: auth.walletToken,
          payload: any(named: 'payload'),
        ),
      ).thenAnswer((_) async => _successOrder());

      final result = await repository.createOrder(_draft());

      final payload =
          verify(
                () => datasource.createOrder(
                  token: auth.walletToken,
                  payload: captureAny(named: 'payload'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(payload['instrument_id'], 'BTC-18MAR26-74100-C');
      expect(payload['side'], 'buy');
      expect(payload['quantity'], 1);
      expect(payload['price'], isNull);
      expect(payload['idempotency_key'], isNotEmpty);
      expect(payload['funding_pubkey_hex'], funding.pubkeyHex);
      expect(result.order.orderId, isNotEmpty);
      verify(
        () => datasource.syncWalletUtxos(
          token: auth.walletToken,
          walletId: auth.walletId,
          utxos: any(named: 'utxos'),
          nonce: any(named: 'nonce'),
        ),
      ).called(2);
      expect(payload.keys, isNot(contains('seed')));
      expect(payload.keys, isNot(contains('mnemonic')));
      expect(payload.keys, isNot(contains('xpriv')));
      expect(payload.keys, isNot(contains('wallet_token')));
      expect(payload.keys, isNot(contains('private_key')));
    });

    test(
      'accepts live STRIKE template and posts resolved instrument id',
      () async {
        when(() => datasource.listInstruments()).thenAnswer(
          (_) async => [
            {'instrument_id': 'BTC-18MAR26-STRIKE-C'},
          ],
        );
        when(
          () => datasource.createOrder(
            token: auth.walletToken,
            payload: any(named: 'payload'),
          ),
        ).thenAnswer((_) async => _successOrder());

        await repository.createOrder(
          const DlcOrderDraft(
            instrumentId: 'BTC-18MAR26-STRIKE-C',
            side: DlcOrderSide.buy,
            quantity: 1,
            price: 0,
            strikePrice: 74100,
            fundingPubkeyHex: '',
          ),
        );

        final payload =
            verify(
                  () => datasource.createOrder(
                    token: auth.walletToken,
                    payload: captureAny(named: 'payload'),
                  ),
                ).captured.single
                as Map<String, dynamic>;
        expect(payload['instrument_id'], 'BTC-18MAR26-74100-C');
      },
    );

    test(
      'recovers order after connection error using idempotency reconcile',
      () async {
        final capturedPayloads = <Map<String, dynamic>>[];
        when(
          () => datasource.createOrder(
            token: auth.walletToken,
            payload: any(named: 'payload'),
          ),
        ).thenAnswer((invocation) async {
          capturedPayloads.add(
            Map<String, dynamic>.from(
              invocation.namedArguments[#payload] as Map<String, dynamic>,
            ),
          );
          throw const DlcApiException(
            statusCode: null,
            message:
                'The connection errored: The connection errored: No route to host',
            isTimeout: false,
            isConnectionError: true,
          );
        });
        when(() => datasource.listOrders(token: auth.walletToken)).thenAnswer(
          (_) async => [
            {
              ..._successOrder(),
              'idempotency_key': capturedPayloads.first['idempotency_key'],
            },
          ],
        );

        final result = await repository.createOrder(_draft());

        expect(result.order.orderId, 'order-1');
        verify(
          () => datasource.createOrder(
            token: auth.walletToken,
            payload: any(named: 'payload'),
          ),
        ).called(2);
      },
    );

    test('retries timeout with the same idempotency key and body', () async {
      var calls = 0;
      when(
        () => datasource.createOrder(
          token: auth.walletToken,
          payload: any(named: 'payload'),
        ),
      ).thenAnswer((_) async {
        calls += 1;
        if (calls == 1) {
          throw const DlcApiException(
            statusCode: null,
            message: 'send timeout',
            isTimeout: true,
          );
        }
        return _successOrder(orderId: 'order-after-timeout');
      });

      await repository.createOrder(_draft());

      final payloads = verify(
        () => datasource.createOrder(
          token: auth.walletToken,
          payload: captureAny(named: 'payload'),
        ),
      ).captured.cast<Map<String, dynamic>>().toList();
      expect(payloads, hasLength(2));
      expect(payloads.first, payloads.last);
      expect(
        payloads.first['idempotency_key'],
        payloads.last['idempotency_key'],
      );
    });

    test(
      'persists response, idempotency key, funding path, wallet and partner',
      () async {
        ApiServiceConstants.dlcCoordinatorPartnerId = 'partner-abc';
        when(
          () => datasource.createOrder(
            token: auth.walletToken,
            payload: any(named: 'payload'),
          ),
        ).thenAnswer((_) async => _successOrder());

        await repository.createOrder(_draft(side: DlcOrderSide.sell));

        final stored = await orderStorage.getByOrderId(
          environment: Environment.testnet,
          walletOriginId: auth.walletOriginId,
          orderId: 'order-1',
        );
        expect(stored, isNotNull);
        expect(stored!['order_id'], 'order-1');
        expect(stored['dlc_id'], 'dlc-1');
        expect(stored['instrument_id'], 'BTC-18MAR26-74100-C');
        expect(stored['side'], 'sell');
        expect(stored['quantity'], 1);
        expect(stored['price'], 12345);
        expect(stored['status'], 'open');
        expect(stored['offer_object_hex'], 'offer-hex');
        expect(stored['idempotency_key'], isNotEmpty);
        expect(stored['funding_pubkey_hex'], funding.pubkeyHex);
        expect(stored['funding_pubkey_derivation'], funding.derivationPath);
        expect(stored['wallet_id'], auth.walletId);
        expect(stored['partner_id'], 'partner-abc');
        expect(stored['created_at'], '2026-05-13T12:00:00Z');
      },
    );

    test(
      'keeps idempotency key after non-reconciled conflict response',
      () async {
        when(
          () => datasource.createOrder(
            token: auth.walletToken,
            payload: any(named: 'payload'),
          ),
        ).thenThrow(
          const DlcApiException(
            statusCode: 409,
            message: 'idempotency conflict',
            isTimeout: false,
          ),
        );
        when(
          () => datasource.listOrders(token: auth.walletToken),
        ).thenAnswer((_) async => const []);

        await expectLater(
          repository.createOrder(_draft()),
          throwsA(isA<DlcApiException>()),
        );

        final raw = storage.values['dlc_idempotency_keys_testnet'];
        expect(raw, isNotNull);
        final decoded = jsonDecode(raw!) as Map<String, dynamic>;
        expect(decoded['createByDraft'], isNotEmpty);
      },
    );
  });

  group('DlcRepository.cancelOrder', () {
    test(
      'removes stale local order when coordinator returns not found',
      () async {
        const staleOrderId = 'stale-order-99';
        await orderStorage.upsertOrder(
          environment: Environment.testnet,
          walletOriginId: auth.walletOriginId,
          values: _successOrder(orderId: staleOrderId),
        );
        when(
          () => datasource.listOrders(token: auth.walletToken),
        ).thenAnswer((_) async => const []);
        when(
          () => datasource.cancelOrder(
            token: auth.walletToken,
            orderId: staleOrderId,
          ),
        ).thenThrow(Exception('HTTP 404: not_found: Order not found'));

        final result = await repository.cancelOrder(staleOrderId);
        expect(result.removedBecauseNotFoundOnCoordinator, isTrue);
        expect(result.order, isNull);

        final orders = await repository.listOrders();
        expect(orders.any((o) => o.orderId == staleOrderId), isFalse);
      },
    );
  });

  group('DlcApiDatasource.createOrder', () {
    test('sends Authorization and X-Partner-Token headers', () async {
      ApiServiceConstants.dlcCoordinatorPartnerToken = 'partner-token';
      final settings = _MockDomainSettingsRepository();
      when(() => settings.fetch()).thenAnswer(
        (_) async => const SettingsEntity(
          environment: Environment.testnet,
          bitcoinUnit: BitcoinUnit.btc,
          currencyCode: 'USD',
        ),
      );
      final adapter = _RecordingAdapter(
        ResponseBody.fromString(
          jsonEncode(_successOrder()),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final dio = Dio(BaseOptions(baseUrl: 'http://coordinator.test'));
      dio.httpClientAdapter = adapter;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            options.headers['X-Partner-Token'] =
                ApiServiceConstants.dlcCoordinatorPartnerToken;
            handler.next(options);
          },
        ),
      );
      final api = DlcApiDatasource(dio: dio, settingsRepository: settings);

      await api.createOrder(token: 'wallet-token', payload: {'a': 1});

      expect(adapter.requestOptions?.method, 'POST');
      expect(adapter.requestOptions?.path, '/orders');
      expect(
        adapter.requestOptions?.headers['Authorization'],
        'Bearer wallet-token',
      );
      expect(
        adapter.requestOptions?.headers['X-Partner-Token'],
        'partner-token',
      );
    });

    for (final status in [400, 401, 403, 404, 409]) {
      test('preserves HTTP $status for response handling', () async {
        final settings = _MockDomainSettingsRepository();
        when(() => settings.fetch()).thenAnswer(
          (_) async => const SettingsEntity(
            environment: Environment.testnet,
            bitcoinUnit: BitcoinUnit.btc,
            currencyCode: 'USD',
          ),
        );
        final dio = Dio(
          BaseOptions(
            baseUrl: 'http://coordinator.test',
            validateStatus: (status) => status != null && status < 300,
          ),
        );
        dio.httpClientAdapter = _RecordingAdapter(
          ResponseBody.fromString(
            jsonEncode({
              'detail': {'message': 'coordinator rejected'},
            }),
            status,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          ),
        );
        final api = DlcApiDatasource(dio: dio, settingsRepository: settings);

        await expectLater(
          api.createOrder(token: 'wallet-token', payload: {'a': 1}),
          throwsA(
            isA<DlcApiException>().having(
              (e) => e.statusCode,
              'statusCode',
              status,
            ),
          ),
        );
      });
    }
  });
}

DlcOrderDraft _draft({DlcOrderSide side = DlcOrderSide.buy}) => DlcOrderDraft(
  instrumentId: 'BTC-18MAR26-74100-C',
  side: side,
  quantity: 1,
  price: 999,
  strikePrice: null,
  fundingPubkeyHex: '',
);

Map<String, dynamic> _successOrder({String orderId = 'order-1'}) => {
  'order_id': orderId,
  'dlc_id': 'dlc-1',
  'instrument_id': 'BTC-18MAR26-74100-C',
  'side': orderId == 'order-1' ? 'sell' : 'buy',
  'quantity': 1,
  'price': 12345,
  'status': 'open',
  'created_at': '2026-05-13T12:00:00Z',
  'offer_object_hex': 'offer-hex',
  'accept_object_hex': null,
  'pending_match_accept': false,
  'matched_order_id': null,
  'matched_dlc_id': null,
  'matched_offer_object_hex': null,
};

class _RecordingAdapter implements HttpClientAdapter {
  final ResponseBody response;
  RequestOptions? requestOptions;

  _RecordingAdapter(this.response);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestOptions = options;
    return response;
  }
}
