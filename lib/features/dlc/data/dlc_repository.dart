import 'package:bb_mobile/core/settings/data/settings_repository.dart';
import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/utils/bip32_derivation.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet.dart';
import 'package:bb_mobile/core/wallet/domain/usecases/get_wallet_utxos_usecase.dart';
import 'package:bb_mobile/features/dlc/data/dlc_api_datasource.dart';
import 'package:bb_mobile/features/dlc/data/dlc_auth_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_idempotency_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_negotiation_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_order_storage.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_instrument_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_local_signer.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_option_payout_simulation.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_negotiation_utils.dart';
import 'package:flutter/foundation.dart';

class DlcRepository {
  final SettingsRepository _settingsRepository;
  final DlcApiDatasource _datasource;
  final DlcAuthStorage _authStorage;
  final DlcIdempotencyStorage _idempotencyStorage;
  final DlcOrderStorage _orderStorage;
  final DlcNegotiationStorage _negotiationStorage;
  final DlcLocalSigner _localSigner;
  final GetWalletUtxosUsecase _getWalletUtxosUsecase;

  DlcRepository({
    required SettingsRepository settingsRepository,
    required DlcApiDatasource datasource,
    required DlcAuthStorage authStorage,
    required DlcIdempotencyStorage idempotencyStorage,
    required DlcOrderStorage orderStorage,
    required DlcNegotiationStorage negotiationStorage,
    required DlcLocalSigner localSigner,
    required GetWalletUtxosUsecase getWalletUtxosUsecase,
  }) : _settingsRepository = settingsRepository,
       _datasource = datasource,
       _authStorage = authStorage,
       _idempotencyStorage = idempotencyStorage,
       _orderStorage = orderStorage,
       _negotiationStorage = negotiationStorage,
       _localSigner = localSigner,
       _getWalletUtxosUsecase = getWalletUtxosUsecase;

  Future<Environment> _environment() async =>
      (await _settingsRepository.fetch()).environment;

  Future<Environment> getAppEnvironment() async => _environment();

  Future<DlcWalletAuth?> getWalletAuth() async {
    return _authStorage.get(await _environment());
  }

  Future<List<DlcWalletAuth>> getAllWalletAuths() async {
    return _authStorage.getAll(await _environment());
  }

  Future<Map<String, dynamic>> getSystemReadiness() async {
    return _datasource.getSystemReadiness();
  }

  Future<List<DlcWalletOption>> listBitcoinWalletOptions() async {
    final env = await _environment();
    final wallets = await _localSigner.getBitcoinWallets(env);
    return wallets
        .where((w) => w.isBitcoin && !w.isLiquid)
        .map(
          (w) => DlcWalletOption(
            walletOriginId: w.id,
            label: (w.label == null || w.label!.trim().isEmpty)
                ? 'Bitcoin wallet'
                : w.label!,
            xpub: Bip32Derivation.getBip32Xpub(w.xpub).toBase58(),
          ),
        )
        .toList(growable: false);
  }

  /// Calls GET /auth/wallet/{walletId} with the stored bearer token.
  /// On success: persists refreshed [expires_at] from the API, returns auth
  /// with the **same** [walletToken]. On 401/403/404: clears storage and returns null.
  Future<DlcWalletAuth?> validateStoredWalletAuth(DlcWalletAuth auth) async {
    final env = await _environment();
    final payload = await _datasource.getWalletOrNullOnAuthFailure(
      token: auth.walletToken,
      walletId: auth.walletId,
    );
    if (payload == null) {
      await _authStorage.clear(env);
      return null;
    }
    final walletId = payload['wallet_id'] as String? ?? auth.walletId;
    final expiresAt = DateTime.tryParse(payload['expires_at'] as String? ?? '');
    final refreshed = DlcWalletAuth(
      walletOriginId: auth.walletOriginId,
      walletLabel: auth.walletLabel,
      walletXpub: auth.walletXpub,
      walletId: walletId,
      walletToken: auth.walletToken,
      expiresAt: expiresAt ?? auth.expiresAt,
    );
    await _authStorage.store(env, refreshed, makeActive: false);
    return refreshed;
  }

  Future<
    ({DlcWalletAuth? activeAuth, List<DlcExpiredWalletInfo> expiredWallets})
  >
  validateAndLoadWalletAuths() async {
    final env = await _environment();
    final stored = await _authStorage.getAll(env);
    if (stored.isEmpty) {
      return (activeAuth: null, expiredWallets: <DlcExpiredWalletInfo>[]);
    }
    final expired = <DlcExpiredWalletInfo>[];
    for (final auth in stored) {
      final validated = await _datasource.getWalletOrNullOnAuthFailure(
        token: auth.walletToken,
        walletId: auth.walletId,
      );
      if (validated == null) {
        expired.add(
          DlcExpiredWalletInfo(walletId: auth.walletId, xpub: auth.walletXpub),
        );
        await _authStorage.removeByWalletOriginId(env, auth.walletOriginId);
        continue;
      }
      final refreshed = DlcWalletAuth(
        walletOriginId: auth.walletOriginId,
        walletLabel: auth.walletLabel,
        walletXpub: auth.walletXpub,
        walletId: validated['wallet_id'] as String? ?? auth.walletId,
        walletToken: auth.walletToken,
        expiresAt:
            DateTime.tryParse(validated['expires_at'] as String? ?? '') ??
            auth.expiresAt,
      );
      await _authStorage.store(env, refreshed, makeActive: false);
    }
    final active = await _authStorage.get(env);
    return (activeAuth: active, expiredWallets: expired);
  }

  Future<List<Map<String, dynamic>>> listInstruments() async {
    final payload = await _datasource.listInstruments();
    return payload.whereType<Map<String, dynamic>>().toList();
  }

  /// Calls `POST /orders/option-payout-simulation` with the active wallet token.
  Future<DlcOptionPayoutSimulationResult> simulateOptionPayout(
    DlcOptionPayoutSimulationRequest request,
  ) async {
    final auth = await getWalletAuth();
    if (auth == null) {
      throw Exception(
        'Register your wallet on the DLC coordinator to run simulations.',
      );
    }
    final raw = await _datasource.simulateOptionPayout(
      token: auth.walletToken,
      payload: request.toJson(),
    );
    return DlcOptionPayoutSimulationResult.fromJson(raw);
  }

  Future<DlcWalletAuth> registerWalletByOriginId(String walletOriginId) async {
    final env = await _environment();
    final wallet = await _localSigner.getBitcoinWalletByOriginId(
      environment: env,
      walletOriginId: walletOriginId,
    );
    final coordinatorXpub = Bip32Derivation.getBip32Xpub(
      wallet.xpub,
    ).toBase58();

    final noncePayload = await _datasource.createNonce();
    final nonce = noncePayload['nonce'] as String? ?? '';
    if (nonce.isEmpty) {
      throw Exception('Coordinator did not return nonce.');
    }

    final signatureCandidates = await _localSigner.signNonceProofCandidates(
      wallet: wallet,
      nonce: nonce,
    );
    final walletUtxos = await _getWalletUtxosUsecase.execute(
      walletId: wallet.id,
    );
    final utxoProofs = await _localSigner.buildUtxoProofs(
      wallet: wallet,
      utxos: walletUtxos,
      nonce: nonce,
    );
    Map<String, dynamic>? registrationPayload;
    Exception? lastError;

    for (final xpubSignature in signatureCandidates) {
      try {
        registrationPayload = await _datasource.registerWallet(
          xpub: coordinatorXpub,
          nonce: nonce,
          xpubSignature: xpubSignature,
          label: wallet.label ?? 'Bull Wallet',
          utxos: utxoProofs,
        );
        break;
      } catch (e) {
        final error = Exception('$e');
        lastError = error;
        final message = e.toString();
        if (!message.contains('auth.wallet.xpub_signature_failed')) {
          rethrow;
        }
      }
    }
    if (registrationPayload == null) {
      throw lastError ??
          Exception('Wallet registration failed: nonce signature invalid.');
    }

    final auth = DlcWalletAuth(
      walletOriginId: wallet.id,
      walletLabel: (wallet.label == null || wallet.label!.trim().isEmpty)
          ? 'Bitcoin wallet'
          : wallet.label!,
      walletXpub: coordinatorXpub,
      walletId: registrationPayload['wallet_id'] as String,
      walletToken: registrationPayload['wallet_token'] as String,
      expiresAt: DateTime.tryParse(
        registrationPayload['expires_at'] as String? ?? '',
      ),
    );
    await _authStorage.store(env, auth);
    return auth;
  }

  /// Pushes locally selected UTXOs to the coordinator and refreshes balances.
  Future<DlcWalletSyncResult> syncActiveWalletUtxos() async {
    final auth = await getWalletAuth();
    if (auth == null) {
      throw Exception('Wallet is not registered for DLC.');
    }
    final env = await _environment();
    final wallet = await _localSigner.getBitcoinWalletByOriginId(
      environment: env,
      walletOriginId: auth.walletOriginId,
    );
    final walletUtxos = await _getWalletUtxosUsecase.execute(
      walletId: wallet.id,
    );
    final noncePayload = await _datasource.createNonce();
    final nonce = noncePayload['nonce'] as String? ?? '';
    if (nonce.isEmpty) {
      throw Exception('Coordinator did not return nonce for UTXO sync.');
    }
    final utxoProofs = await _localSigner.buildUtxoProofs(
      wallet: wallet,
      utxos: walletUtxos,
      nonce: nonce,
    );
    final payload = await _datasource.syncWalletUtxos(
      token: auth.walletToken,
      walletId: auth.walletId,
      nonce: nonce,
      utxos: utxoProofs,
    );
    return DlcWalletSyncResult.fromJson(payload);
  }

  Future<DlcWalletSyncResult?> _trySyncActiveWalletUtxos() async {
    try {
      return await syncActiveWalletUtxos();
    } catch (e) {
      debugPrint('DLC wallet UTXO sync skipped: $e');
      return null;
    }
  }

  Future<void> setActiveWalletOriginId(String walletOriginId) async {
    final env = await _environment();
    await _authStorage.setActiveWalletOriginId(env, walletOriginId);
  }

  Future<DlcOrderSummary> getOrder(String orderId) async {
    final auth = await getWalletAuth();
    if (auth == null) throw Exception('Wallet is not registered for DLC.');
    final env = await _environment();
    final json = await _datasource.getOrder(
      token: auth.walletToken,
      orderId: orderId,
    );
    final local = await _orderStorage.getByOrderId(
      environment: env,
      walletOriginId: auth.walletOriginId,
      orderId: orderId,
    );
    final order = _mapOrder(
      _mergeCoordinatorOrderJson(remote: json, local: local),
    );
    return _mergeOrderWithDlcSnapshot(auth.walletToken, order);
  }

  /// Scans active-wallet orders and runs taker accept / maker sign when required.
  Future<DlcNegotiationPassResult> runNegotiationPass({
    String? focusOrderId,
  }) async {
    final auth = await getWalletAuth();
    if (auth == null) return DlcNegotiationPassResult.skipped();

    final env = await _environment();
    var orders = await listOrders();
    final List<DlcOrderSummary> targets;
    try {
      final resolved = await _resolveNegotiationTargets(
        auth: auth,
        environment: env,
        orders: orders,
        focusOrderId: focusOrderId,
      );
      if (resolved == null) {
        orders = await listOrders();
        return DlcNegotiationPassResult(
          actions: const [],
          errors: const [],
          orders: orders,
        );
      }
      targets = resolved;
    } catch (e) {
      return DlcNegotiationPassResult(
        actions: const [],
        errors: [
          if (focusOrderId != null)
            'Order $focusOrderId not found for negotiation: $e'
          else
            e.toString(),
        ],
        orders: orders,
      );
    }

    final actions = <DlcNegotiationAction>[];
    final errors = <String>[];

    for (final order in targets) {
      if (!needsDlcNegotiation(order)) continue;
      try {
        final action = await _negotiateOrderIfNeeded(
          auth: auth,
          order: order,
        );
        if (action != null) {
          actions.add(action);
        }
      } catch (e) {
        if (isCoordinatorOrderNotFound(e)) {
          await _abandonOrderNotOnCoordinator(
            environment: env,
            auth: auth,
            orderId: order.orderId,
          );
          continue;
        }
        errors.add('${order.orderId}: $e');
      }
    }

    orders = await listOrders();
    return DlcNegotiationPassResult(
      actions: actions,
      errors: errors,
      orders: orders,
    );
  }

  /// Whether any loaded order still needs an automated negotiation pass.
  Future<bool> hasOrdersNeedingNegotiation() async {
    final orders = await listOrders();
    return orders.any(needsDlcNegotiation);
  }

  Future<List<DlcOrderSummary>> listOrders() async {
    final auth = await getWalletAuth();
    if (auth == null) return [];
    final env = await _environment();
    final localSnapshots = await _orderStorage.listForWallet(
      environment: env,
      walletOriginId: auth.walletOriginId,
    );
    final localByOrderId = <String, Map<String, dynamic>>{
      for (final snapshot in localSnapshots)
        if (snapshot['order_id'] != null)
          snapshot['order_id'].toString(): snapshot,
    };
    final payload = await _datasource.listOrders(token: auth.walletToken);
    final mapped = payload
        .whereType<Map<String, dynamic>>()
        .map(
          (json) => _mapOrder(
            _mergeCoordinatorOrderJson(
              remote: json,
              local: localByOrderId[json['order_id']?.toString()],
            ),
          ),
        )
        .toList(growable: false);
    final merged = await Future.wait(
      mapped.map((o) => _mergeOrderWithDlcSnapshot(auth.walletToken, o)),
    );
    for (final json in payload.whereType<Map<String, dynamic>>()) {
      await _persistOrderSnapshot(environment: env, auth: auth, values: json);
    }
    return _appendLocalOnlyOrders(
      environment: env,
      walletOriginId: auth.walletOriginId,
      remote: merged,
      local: localSnapshots,
    );
  }

  Future<DlcCancelOrderResult> cancelOrder(String orderId) async {
    final auth = await getWalletAuth();
    if (auth == null) throw Exception('Wallet is not registered for DLC.');
    final env = await _environment();
    try {
      final json = await _datasource.cancelOrder(
        token: auth.walletToken,
        orderId: orderId,
      );
      final syncAfter = await _trySyncActiveWalletUtxos();
      return DlcCancelOrderResult(
        order: _mapOrder(json),
        syncAfter: syncAfter,
      );
    } catch (e) {
      if (isCoordinatorOrderNotFound(e)) {
        await _abandonOrderNotOnCoordinator(
          environment: env,
          auth: auth,
          orderId: orderId,
        );
        return const DlcCancelOrderResult.staleRemovedLocally();
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> getWalletBalances() async {
    final auth = await getWalletAuth();
    if (auth == null) return null;
    return _datasource.getWallet(
      token: auth.walletToken,
      walletId: auth.walletId,
    );
  }

  Future<Map<String, dynamic>> getOrderbook(String instrumentId) async {
    return _datasource.getOrderbook(instrumentId: instrumentId);
  }

  Future<double> getBtcUsdSpotPrice() => _datasource.getBtcUsdSpotPrice();

  List<double> buildSuggestedStrikePrices(double spotPrice) {
    final roundedSpot = (spotPrice / 1000).round() * 1000;
    return List<double>.generate(
      11,
      (index) => (roundedSpot + ((index - 5) * 1000)).toDouble(),
    ).where((strike) => strike > 0).toList(growable: false);
  }

  Future<DlcCreateOrderResult> createOrder(DlcOrderDraft draft) async {
    final auth = await getWalletAuth();
    if (auth == null) throw Exception('Wallet is not registered for DLC.');
    final expiresAt = auth.expiresAt;
    if (expiresAt != null && !expiresAt.isAfter(DateTime.now().toUtc())) {
      throw Exception(
        'Wallet token expired. Refresh or re-register this DLC wallet.',
      );
    }
    if (draft.quantity <= 0) {
      throw Exception('Order quantity must be positive.');
    }
    if (draft.price < 0) {
      throw Exception('Premium per contract cannot be negative.');
    }
    final syncBefore = await syncActiveWalletUtxos();
    final env = await _environment();
    final wallet = await _localSigner.getBitcoinWalletByOriginId(
      environment: env,
      walletOriginId: auth.walletOriginId,
    );
    final resolvedInstrumentId = _resolveCreateInstrumentId(draft);
    await _ensureLiveInstrumentId(
      selectedInstrumentId: draft.instrumentId,
      resolvedInstrumentId: resolvedInstrumentId,
    );
    final funding = draft.fundingPubkeyHex.isEmpty
        ? await _localSigner.deriveFundingPubkey(wallet: wallet)
        : DlcFundingPubkey(
            pubkeyHex: draft.fundingPubkeyHex,
            derivationPath: _localSigner.fundingDerivationPath(wallet),
          );
    final draftFingerprint =
        '$resolvedInstrumentId|${draft.side.value}|${draft.quantity}|${draft.strikePrice}|${funding.pubkeyHex}';
    final idempotencyKey = await _idempotencyStorage.getOrCreateCreateDraftKey(
      environment: env,
      draftFingerprint: draftFingerprint,
    );
    final request = {
      'instrument_id': resolvedInstrumentId,
      'side': draft.side.value,
      'quantity': draft.quantity,
      'price': null,
      'idempotency_key': idempotencyKey,
      'funding_pubkey_hex': funding.pubkeyHex,
    };
    try {
      final payload = await _createOrderWithSingleTransientRetry(
        token: auth.walletToken,
        payload: request,
      );
      final order = await _finalizeCreatedOrder(
        environment: env,
        auth: auth,
        draft: draft,
        draftFingerprint: draftFingerprint,
        funding: funding,
        idempotencyKey: idempotencyKey,
        payload: payload,
        walletId: auth.walletId,
      );
      await _trySyncActiveWalletUtxos();
      return DlcCreateOrderResult(
        order: order,
        syncBefore: syncBefore,
      );
    } catch (e) {
      final reconciled = await _tryReconcileCreatedOrder(
        environment: env,
        auth: auth,
        draft: draft,
        draftFingerprint: draftFingerprint,
        funding: funding,
        idempotencyKey: idempotencyKey,
        error: e,
      );
      if (reconciled != null) {
        await _trySyncActiveWalletUtxos();
        return DlcCreateOrderResult(
          order: reconciled,
          syncBefore: syncBefore,
        );
      }
      final keepForReconcile =
          e is DlcApiException && e.statusCode == 409 ||
          _isTransientCreateOrderFailure(e);
      if (!keepForReconcile) {
        await _idempotencyStorage.clearCreateDraftKey(
          environment: env,
          draftFingerprint: draftFingerprint,
        );
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _createOrderWithSingleTransientRetry({
    required String token,
    required Map<String, dynamic> payload,
  }) async {
    try {
      return await _datasource.createOrder(token: token, payload: payload);
    } catch (e) {
      if (!_isTransientCreateOrderFailure(e)) rethrow;
      return _datasource.createOrder(token: token, payload: payload);
    }
  }

  Future<DlcOrderSummary> _finalizeCreatedOrder({
    required Environment environment,
    required DlcWalletAuth auth,
    required DlcOrderDraft draft,
    required String draftFingerprint,
    required DlcFundingPubkey funding,
    required String idempotencyKey,
    required Map<String, dynamic> payload,
    required String walletId,
  }) async {
    final snapshot = _createdOrderSnapshot(
      payload: payload,
      idempotencyKey: idempotencyKey,
      draft: draft,
      funding: funding,
      walletId: walletId,
    );
    await _persistOrderSnapshot(
      environment: environment,
      auth: auth,
      values: snapshot,
    );
    await _idempotencyStorage.clearCreateDraftKey(
      environment: environment,
      draftFingerprint: draftFingerprint,
    );
    return _mapOrder(snapshot);
  }

  Map<String, dynamic> _createdOrderSnapshot({
    required Map<String, dynamic> payload,
    required String idempotencyKey,
    required DlcOrderDraft draft,
    required DlcFundingPubkey funding,
    required String walletId,
  }) {
    final matchRole =
        (payload['pending_match_accept'] as bool? ?? false) ? 'taker' : 'maker';
    return {
      ...payload,
      'match_role': matchRole,
      'idempotency_key': idempotencyKey,
      'strike_price': draft.strikePrice,
      'funding_pubkey_hex': funding.pubkeyHex,
      'funding_pubkey_derivation': funding.derivationPath,
      'wallet_id': walletId,
      'partner_id': ApiServiceConstants.dlcCoordinatorPartnerId,
    };
  }

  Future<DlcOrderSummary?> _tryReconcileCreatedOrder({
    required Environment environment,
    required DlcWalletAuth auth,
    required DlcOrderDraft draft,
    required String draftFingerprint,
    required DlcFundingPubkey funding,
    required String idempotencyKey,
    required Object error,
  }) async {
    final shouldReconcile =
        (error is DlcApiException && error.statusCode == 409) ||
        _isTransientCreateOrderFailure(error);
    if (!shouldReconcile) return null;

    final existing = await _reconcileCreateConflict(
      environment: environment,
      auth: auth,
      idempotencyKey: idempotencyKey,
    );
    if (existing == null) return null;

    final snapshot = _createdOrderSnapshot(
      payload: {
        'order_id': existing.orderId,
        'dlc_id': existing.dlcId,
        'instrument_id': existing.instrumentId,
        'side': existing.side,
        'quantity': existing.quantity,
        'price': existing.price,
        'status': existing.status,
        'created_at': existing.createdAt?.toUtc().toIso8601String(),
        'pending_match_accept': existing.pendingMatchAccept,
        'matched_order_id': existing.matchedOrderId,
        'match_role': existing.matchRole,
        'is_maker': existing.isMaker,
      },
      idempotencyKey: idempotencyKey,
      draft: draft,
      funding: funding,
      walletId: auth.walletId,
    );
    await _persistOrderSnapshot(
      environment: environment,
      auth: auth,
      values: snapshot,
    );
    await _idempotencyStorage.clearCreateDraftKey(
      environment: environment,
      draftFingerprint: draftFingerprint,
    );
    return _mapOrder(snapshot);
  }

  Future<DlcOrderSummary?> _reconcileCreateConflict({
    required Environment environment,
    required DlcWalletAuth auth,
    required String idempotencyKey,
  }) async {
    final orders = await _datasource.listOrders(token: auth.walletToken);
    for (final json in orders.whereType<Map<String, dynamic>>()) {
      if (json['idempotency_key']?.toString() != idempotencyKey) continue;
      await _persistOrderSnapshot(
        environment: environment,
        auth: auth,
        values: json,
      );
      return _mapOrder(json);
    }
    return null;
  }

  Future<void> _ensureLiveInstrumentId({
    required String selectedInstrumentId,
    required String resolvedInstrumentId,
  }) async {
    final instruments = await listInstruments();
    final found = instruments.any((i) {
      final liveId = dlcInstrumentId(i);
      if (liveId == resolvedInstrumentId) return true;
      return selectedInstrumentId.contains('-STRIKE-') &&
          liveId == selectedInstrumentId;
    });
    if (!found) {
      throw Exception(
        'Selected instrument is no longer live. Refresh instruments and choose again.',
      );
    }
  }

  bool _isTimeoutError(Object e) {
    if (e is DlcApiException) return e.isTimeout;
    final msg = e.toString().toLowerCase();
    return msg.contains('timeout') || msg.contains('timed out');
  }

  /// Network failures where the coordinator may still have persisted the order.
  bool _isTransientCreateOrderFailure(Object e) {
    if (e is DlcApiException) {
      if (e.isTimeout || e.isConnectionError) return true;
      if (e.statusCode != null) return false;
      final msg = e.message.toLowerCase();
      return msg.contains('connection errored') ||
          msg.contains('connection error') ||
          msg.contains('no route to host') ||
          msg.contains('network is unreachable') ||
          msg.contains('failed host lookup') ||
          msg.contains('socketexception');
    }
    final msg = e.toString().toLowerCase();
    return _isTimeoutError(e) ||
        msg.contains('connection errored') ||
        msg.contains('no route to host');
  }

  /// Advances an order through coordinator API state transitions using the
  /// documented flow:
  /// - pending_accept -> accept-context -> accept-match (taker)
  /// - sign_required + maker -> sign-context -> sign
  /// Then reads settlement status for current DLC snapshot.
  Future<DlcOrderSummary> progressOrderLifecycle({
    required String orderId,
    int maxSteps = 6,
  }) async {
    await _trySyncActiveWalletUtxos();
    final auth = await getWalletAuth();
    if (auth == null) throw Exception('Wallet is not registered for DLC.');
    final env = await _environment();
    final wallet = await _localSigner.getBitcoinWalletByOriginId(
      environment: env,
      walletOriginId: auth.walletOriginId,
    );
    final fundingPubkey = await _localSigner.deriveFundingPubkeyHex(
      wallet: wallet,
    );

    var current = _mapOrder(
      await _datasource.getOrder(token: auth.walletToken, orderId: orderId),
    );
    var steps = 0;

    while (steps < maxSteps) {
      steps += 1;
      current = _mapOrder(
        await _datasource.getOrder(token: auth.walletToken, orderId: orderId),
      );

      if (needsDlcTakerAccept(current)) {
        await _submitAcceptArtifacts(
          environment: env,
          token: auth.walletToken,
          wallet: wallet,
          orderId: current.orderId,
          fundingPubkeyHex: fundingPubkey,
        );
        continue;
      }

      if (needsDlcMakerSign(current)) {
        try {
          await _submitMakerSignArtifacts(
            environment: env,
            token: auth.walletToken,
            wallet: wallet,
            dlcId: current.dlcId!,
            orderId: current.orderId,
            fundingPubkeyHex: fundingPubkey,
          );
          continue;
        } catch (e) {
          final msg = e.toString().toLowerCase();
          if (!msg.contains(
                'only the maker-side dlc may request sign-context',
              ) &&
              !msg.contains('must be accepted to sign') &&
              !msg.contains('state_conflict')) {
            rethrow;
          }
        }
      }

      break;
    }

    current = _mapOrder(
      await _datasource.getOrder(token: auth.walletToken, orderId: orderId),
    );

    if (current.dlcId != null) {
      try {
        final settlement = await _datasource.getDlcStatus(
          token: auth.walletToken,
          dlcId: current.dlcId!,
        );
        final detail = await _datasource.getDlc(
          token: auth.walletToken,
          dlcId: current.dlcId!,
        );
        current = _mergeSettlementAndDetail(current, settlement, detail);
      } catch (e) {
        debugPrint('DLC settlement/detail fetch skipped: $e');
      }
    }

    if (current.fundingTxid != null && current.fundingTxid!.isNotEmpty) {
      await _trySyncActiveWalletUtxos();
    }

    return current;
  }

  /// Same as [progressOrderLifecycle] — kept for call sites that used the old name.
  Future<DlcOrderSummary> fillAndProcessOrder({required String orderId}) async {
    return progressOrderLifecycle(orderId: orderId, maxSteps: 8);
  }

  Future<DlcNegotiationAction?> _negotiateOrderIfNeeded({
    required DlcWalletAuth auth,
    required DlcOrderSummary order,
  }) async {
    if (isDlcNegotiationComplete(order)) return null;

    final env = await _environment();
    final wallet = await _localSigner.getBitcoinWalletByOriginId(
      environment: env,
      walletOriginId: auth.walletOriginId,
    );
    final funding = await _resolveFundingPubkey(
      environment: env,
      auth: auth,
      wallet: wallet,
      orderId: order.orderId,
    );

    if (needsDlcTakerAccept(order)) {
      await _submitAcceptArtifacts(
        environment: env,
        token: auth.walletToken,
        wallet: wallet,
        orderId: order.orderId,
        fundingPubkeyHex: funding.pubkeyHex,
      );
      return DlcNegotiationAction(
        kind: DlcNegotiationActionKind.takerAccept,
        orderId: order.orderId,
        dlcId: order.dlcId,
      );
    }

    if (needsDlcMakerSign(order) && order.dlcId != null) {
      await _submitMakerSignArtifacts(
        environment: env,
        token: auth.walletToken,
        wallet: wallet,
        dlcId: order.dlcId!,
        orderId: order.orderId,
        fundingPubkeyHex: funding.pubkeyHex,
      );
      return DlcNegotiationAction(
        kind: DlcNegotiationActionKind.makerSign,
        orderId: order.orderId,
        dlcId: order.dlcId,
      );
    }

    return null;
  }

  Future<DlcFundingPubkey> _resolveFundingPubkey({
    required Environment environment,
    required DlcWalletAuth auth,
    required Wallet wallet,
    required String orderId,
  }) async {
    final stored = await _negotiationStorage.getOrderState(
      environment: environment,
      walletOriginId: auth.walletOriginId,
      orderId: orderId,
    );
    final storedPubkey = stored?['funding_pubkey_hex'] as String?;
    final storedPath = stored?['funding_pubkey_derivation'] as String?;
    if (storedPubkey != null &&
        storedPubkey.isNotEmpty &&
        storedPath != null &&
        storedPath.isNotEmpty) {
      return DlcFundingPubkey(
        pubkeyHex: storedPubkey,
        derivationPath: storedPath,
      );
    }
    final funding = await _localSigner.deriveFundingPubkey(wallet: wallet);
    await _negotiationStorage.upsertOrderState(
      environment: environment,
      walletOriginId: auth.walletOriginId,
      orderId: orderId,
      values: {
        'funding_pubkey_hex': funding.pubkeyHex,
        'funding_pubkey_derivation': funding.derivationPath,
      },
    );
    return funding;
  }

  Future<void> _submitAcceptArtifacts({
    required Environment environment,
    required String token,
    required Wallet wallet,
    required String orderId,
    required String fundingPubkeyHex,
  }) async {
    await syncActiveWalletUtxos();
    for (var attempt = 0; attempt < 2; attempt++) {
      final context = await _datasource.acceptContext(
        token: token,
        orderId: orderId,
        fundingPubkeyHex: fundingPubkeyHex,
      );
      final fingerprint = context['context_fingerprint'] as String? ?? '';
      final idempotencyKey =
          await _idempotencyStorage.getOrCreateAcceptKeyForFingerprint(
        environment: environment,
        orderId: orderId,
        contextFingerprint: fingerprint,
      );
      final auth = await getWalletAuth();
      if (auth != null) {
        await _persistOrderSnapshot(
          environment: environment,
          auth: auth,
          values: {
            'order_id': orderId,
            'accept_context_fingerprint': fingerprint,
            'accept_context_snapshot': context,
            'accept_idempotency_key': idempotencyKey,
            'funding_pubkey_hex': fundingPubkeyHex,
            'negotiation_status': 'accept_pending',
          },
        );
        await _negotiationStorage.upsertOrderState(
          environment: environment,
          walletOriginId: auth.walletOriginId,
          orderId: orderId,
          values: {
            'funding_pubkey_hex': fundingPubkeyHex,
            'accept_context_fingerprint': fingerprint,
            'negotiation_status': 'accept_pending',
          },
        );
      }
      final signed = await _localSigner.signDlcContext(
        wallet: wallet,
        contextTag: 'accept',
        context: context,
        fundingPubkeyHex: fundingPubkeyHex,
      );
      try {
        final accepted = await _datasource.acceptMatch(
          token: token,
          orderId: orderId,
          payload: {
            'funding_pubkey_hex': signed.fundingPubkeyHex,
            'context_fingerprint': fingerprint,
            'context_snapshot': context,
            'idempotency_key': idempotencyKey,
            'cet_adaptor_signatures_hex': signed.cetAdaptorSignaturesHex,
            'refund_signature_hex': signed.refundSignatureHex,
            'funding_signatures_hex': signed.fundingSignaturesHex,
          },
        );
        if (auth != null) {
          await _persistOrderSnapshot(
            environment: environment,
            auth: auth,
            values: {
              ...accepted,
              'accept_context_fingerprint': fingerprint,
              'accept_idempotency_key': idempotencyKey,
            },
          );
          await _negotiationStorage.upsertOrderState(
            environment: environment,
            walletOriginId: auth.walletOriginId,
            orderId: orderId,
            values: {
              'accept_context_fingerprint': fingerprint,
              'negotiation_status': 'accept_submitted',
            },
          );
        }
        await _idempotencyStorage.clearAcceptKey(
          environment: environment,
          orderId: orderId,
          contextFingerprint: fingerprint,
        );
        return;
      } catch (e) {
        if (_isContextMismatch(e) && attempt == 0) {
          await _idempotencyStorage.rotateAcceptKey(
            environment: environment,
            orderId: orderId,
            contextFingerprint: fingerprint,
          );
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> _submitMakerSignArtifacts({
    required Environment environment,
    required String token,
    required Wallet wallet,
    required String dlcId,
    required String orderId,
    required String fundingPubkeyHex,
  }) async {
    final auth = await getWalletAuth();
    for (var attempt = 0; attempt < 2; attempt++) {
      final signContext = await _datasource.signContext(
        token: token,
        dlcId: dlcId,
      );
      final fingerprint = signContext['context_fingerprint'] as String? ??
          signContext['fingerprint'] as String? ??
          '';
      final idempotencyKey =
          await _idempotencyStorage.getOrCreateSignKeyForFingerprint(
        environment: environment,
        dlcId: dlcId,
        contextFingerprint: fingerprint,
      );
      if (auth != null) {
        await _negotiationStorage.upsertOrderState(
          environment: environment,
          walletOriginId: auth.walletOriginId,
          orderId: orderId,
          values: {
            'funding_pubkey_hex': fundingPubkeyHex,
            'sign_context_fingerprint': fingerprint,
            'negotiation_status': 'sign_pending',
          },
        );
      }
      final makerSigned = await _localSigner.signDlcContext(
        wallet: wallet,
        contextTag: 'sign',
        context: signContext,
        fundingPubkeyHex: fundingPubkeyHex,
      );
      try {
        final signedResponse = await _datasource.signDlc(
          token: token,
          dlcId: dlcId,
          payload: {
            'cet_adaptor_signatures_hex': makerSigned.cetAdaptorSignaturesHex,
            'refund_signature_hex': makerSigned.refundSignatureHex,
            'funding_signatures_hex': makerSigned.fundingSignaturesHex,
            'idempotency_key': idempotencyKey,
          },
        );
        if (auth != null) {
          await _orderStorage.upsertDlc(
            environment: environment,
            walletOriginId: auth.walletOriginId,
            dlcId: dlcId,
            values: {
              ...signedResponse,
              'sign_idempotency_key': idempotencyKey,
              'funding_pubkey_hex': fundingPubkeyHex,
            },
          );
          await _negotiationStorage.upsertOrderState(
            environment: environment,
            walletOriginId: auth.walletOriginId,
            orderId: orderId,
            values: {
              'sign_context_fingerprint': fingerprint,
              'negotiation_status': 'sign_submitted',
            },
          );
        }
        await _idempotencyStorage.clearSignKey(
          environment: environment,
          dlcId: dlcId,
          contextFingerprint: fingerprint,
        );
        final fundingTxid = signedResponse['funding_txid'] as String?;
        if (fundingTxid != null && fundingTxid.isNotEmpty) {
          await _trySyncActiveWalletUtxos();
        }
        return;
      } catch (e) {
        if (_isContextMismatch(e) && attempt == 0) {
          await _idempotencyStorage.rotateSignKey(
            environment: environment,
            dlcId: dlcId,
            contextFingerprint: fingerprint,
          );
          continue;
        }
        rethrow;
      }
    }
  }

  bool _isContextMismatch(Object e) {
    final m = e.toString().toLowerCase();
    return m.contains('context_mismatch') ||
        m.contains('stale_context') ||
        m.contains('stale_accept_context');
  }

  Future<DlcOrderSummary> _mergeOrderWithDlcSnapshot(
    String token,
    DlcOrderSummary order,
  ) async {
    if (order.dlcId == null) return order;
    try {
      final detail = await _datasource.getDlc(
        token: token,
        dlcId: order.dlcId!,
      );
      return _mergeDlcDetailIntoOrder(order, detail);
    } catch (_) {
      return order;
    }
  }

  Future<void> _persistOrderSnapshot({
    required Environment environment,
    required DlcWalletAuth auth,
    required Map<String, dynamic> values,
  }) async {
    final orderId = values['order_id']?.toString() ?? values['id']?.toString();
    if (orderId == null || orderId.isEmpty) return;
    await _orderStorage.upsertOrder(
      environment: environment,
      walletOriginId: auth.walletOriginId,
      values: {...values, 'order_id': orderId},
    );
  }

  Future<List<DlcOrderSummary>?> _resolveNegotiationTargets({
    required DlcWalletAuth auth,
    required Environment environment,
    required List<DlcOrderSummary> orders,
    String? focusOrderId,
  }) async {
    if (focusOrderId != null) {
      if (await _negotiationStorage.isOrderAbandonedNotFound(
        environment: environment,
        walletOriginId: auth.walletOriginId,
        orderId: focusOrderId,
      )) {
        return null;
      }
      final focused = orders
          .where((order) => order.orderId == focusOrderId)
          .toList(growable: false);
      if (focused.isNotEmpty) {
        return focused;
      }
      try {
        return [await getOrder(focusOrderId)];
      } catch (e) {
        if (isCoordinatorOrderNotFound(e)) {
          await _abandonOrderNotOnCoordinator(
            environment: environment,
            auth: auth,
            orderId: focusOrderId,
          );
          return null;
        }
        rethrow;
      }
    }

    final targets = <DlcOrderSummary>[];
    for (final order in orders) {
      if (!needsDlcNegotiation(order)) continue;
      if (await _negotiationStorage.isOrderAbandonedNotFound(
        environment: environment,
        walletOriginId: auth.walletOriginId,
        orderId: order.orderId,
      )) {
        continue;
      }
      targets.add(order);
    }
    return targets;
  }

  Future<void> _abandonOrderNotOnCoordinator({
    required Environment environment,
    required DlcWalletAuth auth,
    required String orderId,
  }) async {
    await _negotiationStorage.markOrderNotFoundOnCoordinator(
      environment: environment,
      walletOriginId: auth.walletOriginId,
      orderId: orderId,
    );
    await _orderStorage.removeOrder(
      environment: environment,
      walletOriginId: auth.walletOriginId,
      orderId: orderId,
    );
  }

  Future<List<DlcOrderSummary>> _appendLocalOnlyOrders({
    required Environment environment,
    required String walletOriginId,
    required List<DlcOrderSummary> remote,
    required List<Map<String, dynamic>> local,
  }) async {
    final remoteIds = remote.map((o) => o.orderId).toSet();
    final localOnly = <DlcOrderSummary>[];
    for (final json in local) {
      final orderId = json['order_id']?.toString();
      if (orderId == null || orderId.isEmpty || remoteIds.contains(orderId)) {
        continue;
      }
      if (await _negotiationStorage.isOrderAbandonedNotFound(
        environment: environment,
        walletOriginId: walletOriginId,
        orderId: orderId,
      )) {
        continue;
      }
      localOnly.add(_mapOrder(json));
    }
    return [...remote, ...localOnly];
  }

  DlcOrderSummary _mergeSettlementAndDetail(
    DlcOrderSummary current,
    Map<String, dynamic> settlement,
    Map<String, dynamic> detail,
  ) {
    final merged = _mergeDlcDetailIntoOrder(current, detail);
    return DlcOrderSummary(
      orderId: merged.orderId,
      dlcId: merged.dlcId,
      status: merged.status,
      pendingMatchAccept: merged.pendingMatchAccept,
      matchedOrderId: merged.matchedOrderId,
      matchedDlcId: merged.matchedDlcId,
      isMaker: merged.isMaker,
      matchRole: merged.matchRole,
      signRequired: merged.signRequired,
      dlcStatus: (settlement['status'] ?? merged.dlcStatus)?.toString(),
      settlementType: (settlement['settlement_type'] ?? merged.settlementType)
          ?.toString(),
      confirmationStatus:
          (detail['confirmation_status'] ?? merged.confirmationStatus)
              ?.toString(),
      instrumentId: merged.instrumentId,
      side: merged.side,
      quantity: merged.quantity,
      price: merged.price,
      createdAt: merged.createdAt,
      sideCollateralSat: merged.sideCollateralSat,
      partnerFeeSat: merged.partnerFeeSat,
      networkFeeSat: merged.networkFeeSat,
      lastErrorReason: merged.lastErrorReason,
      lastErrorMessage: merged.lastErrorMessage,
      oracleOutcomeValue: merged.oracleOutcomeValue,
      fundingTxid: merged.fundingTxid,
      closingTxid: merged.closingTxid,
      refundTxid: merged.refundTxid,
    );
  }

  DlcOrderSummary _mergeDlcDetailIntoOrder(
    DlcOrderSummary o,
    Map<String, dynamic> d,
  ) {
    return DlcOrderSummary(
      orderId: o.orderId,
      dlcId: o.dlcId,
      status: o.status,
      pendingMatchAccept: o.pendingMatchAccept,
      matchedOrderId: o.matchedOrderId,
      matchedDlcId: o.matchedDlcId,
      isMaker: o.isMaker,
      matchRole: o.matchRole,
      signRequired: o.signRequired,
      dlcStatus: d['status']?.toString() ?? o.dlcStatus,
      settlementType: d['settlement_type']?.toString() ?? o.settlementType,
      confirmationStatus: o.confirmationStatus,
      instrumentId: o.instrumentId,
      side: o.side,
      quantity: o.quantity,
      price: o.price,
      createdAt: o.createdAt,
      sideCollateralSat:
          _readNumber(d, [
            'side_collateral_sats',
            'side_collateral_sat',
            'collateral_sats',
            'collateral_sat',
          ]) ??
          o.sideCollateralSat,
      partnerFeeSat:
          _readNumber(d, [
            'partner_fee_sats',
            'partner_fee_sat',
            'partner_fee',
            'fees_paid_to_partner_sats',
            'fees_paid_to_partner',
          ]) ??
          o.partnerFeeSat,
      networkFeeSat:
          _readNumber(d, [
            'network_fee_sats',
            'network_fee_sat',
            'network_fee',
            'mining_fee_sats',
            'mining_fee',
          ]) ??
          o.networkFeeSat,
      lastErrorReason: d['last_error_reason'] as String? ?? o.lastErrorReason,
      lastErrorMessage:
          d['last_error_message'] as String? ?? o.lastErrorMessage,
      oracleOutcomeValue:
          d['oracle_outcome_value'] as String? ?? o.oracleOutcomeValue,
      fundingTxid: d['funding_txid'] as String? ?? o.fundingTxid,
      closingTxid: d['closing_txid'] as String? ?? o.closingTxid,
      refundTxid: d['refund_txid'] as String? ?? o.refundTxid,
    );
  }

  Map<String, dynamic> _mergeCoordinatorOrderJson({
    required Map<String, dynamic> remote,
    Map<String, dynamic>? local,
  }) {
    if (local == null) return remote;
    final merged = <String, dynamic>{...local, ...remote};
    final matchRole = remote['match_role'] ?? local['match_role'] ?? local['role'];
    if (matchRole != null) {
      merged['match_role'] = matchRole;
    }
    if (remote['is_maker'] == null && local['is_maker'] != null) {
      merged['is_maker'] = local['is_maker'];
    }
    if (remote['pending_match_accept'] != true &&
        local['pending_match_accept'] == true) {
      merged['pending_match_accept'] = true;
    }
    return merged;
  }

  DlcOrderSummary _mapOrder(Map<String, dynamic> json) {
    final status = json['status'] as String? ?? 'unknown';
    final pendingMatchAccept = json['pending_match_accept'] as bool? ?? false;

    final matchRoleRaw =
        json['match_role'] as String? ?? json['role'] as String?;
    bool? isMaker = json['is_maker'] as bool?;
    final role = matchRoleRaw?.toLowerCase();
    if (isMaker == null && role == 'maker') {
      isMaker = true;
    } else if (isMaker == null && role == 'taker') {
      isMaker = false;
    }

    final qty = json['quantity'];
    final price = json['price'];
    final side = json['side'] as String?;

    return DlcOrderSummary(
      orderId: json['order_id'] as String? ?? json['id'] as String? ?? '',
      dlcId: json['dlc_id'] as String?,
      status: status,
      pendingMatchAccept: pendingMatchAccept,
      matchedOrderId: json['matched_order_id'] as String?,
      matchedDlcId: json['matched_dlc_id'] as String?,
      isMaker: isMaker,
      matchRole: matchRoleRaw,
      signRequired: json['sign_required'] as bool?,
      dlcStatus: json['dlc_status'] as String?,
      settlementType: json['settlement_type'] as String?,
      confirmationStatus: json['confirmation_status'] as String?,
      instrumentId: json['instrument_id'] as String?,
      side: side,
      quantity: qty is num ? qty.toDouble() : null,
      price: price is num ? price.toDouble() : null,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      sideCollateralSat: _readSideCollateral(json, side),
      partnerFeeSat: _readNumber(json, [
        'partner_fee_sats',
        'partner_fee_sat',
        'partner_fee',
        'fees_paid_to_partner_sats',
        'fees_paid_to_partner',
      ]),
      networkFeeSat: _readNumber(json, [
        'network_fee_sats',
        'network_fee_sat',
        'network_fee',
        'mining_fee_sats',
        'mining_fee',
      ]),
      lastErrorReason: json['last_error_reason'] as String?,
      lastErrorMessage: json['last_error_message'] as String?,
      oracleOutcomeValue: json['oracle_outcome_value'] as String?,
      fundingTxid: json['funding_txid'] as String?,
      closingTxid: json['closing_txid'] as String?,
      refundTxid: json['refund_txid'] as String?,
    );
  }

  double? _readSideCollateral(Map<String, dynamic> json, String? side) {
    final sideLower = side?.toLowerCase();
    if (sideLower == 'buy') {
      return _readNumber(json, [
        'buyer_collateral_sats',
        'buy_collateral_sats',
        'long_collateral_sats',
        'side_collateral_sats',
        'collateral_sats',
      ]);
    }
    if (sideLower == 'sell') {
      return _readNumber(json, [
        'seller_collateral_sats',
        'sell_collateral_sats',
        'short_collateral_sats',
        'side_collateral_sats',
        'collateral_sats',
      ]);
    }
    return _readNumber(json, [
      'side_collateral_sats',
      'collateral_sats',
      'collateral_sat',
    ]);
  }

  double? _readNumber(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is num) return value.toDouble();
      if (value is String) {
        final parsed = double.tryParse(value);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  String _resolveCreateInstrumentId(DlcOrderDraft draft) {
    final templateId = draft.instrumentId.trim();
    if (!templateId.contains('-STRIKE-')) {
      return templateId;
    }
    final strikePrice = draft.strikePrice;
    if (strikePrice == null || strikePrice <= 0) {
      throw Exception('Strike price is required for STRIKE instruments');
    }
    final strike = dlcNormalizeStrikeToken(strikePrice);
    return templateId.replaceFirst('-STRIKE-', '-$strike-');
  }
}
