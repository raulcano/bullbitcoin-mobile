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
import 'package:bb_mobile/features/dlc/domain/dlc_dlc_detail_sync_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_negotiation_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_order_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_wallet_pnl_utils.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_wallet_utxo_projection_utils.dart';
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

  final Map<String, _CachedDlcDetail> _dlcDetailCacheByKey = {};

  /// Bump when the canonical-DLC migration changes the local cache shape.
  ///
  /// Old wallets stored an ad-hoc maker DLC + counterparty DLC pair, plus
  /// `matched_order_id` / `matched_dlc_id` snapshots that the new model no
  /// longer understands. On first launch after upgrade, we wipe the local
  /// order/negotiation/idempotency caches (auth/keys are preserved) so the
  /// next list refresh rebuilds state from `executions[]`.
  static const int _dlcSchemaVersion = 2;
  bool _dlcSchemaCutoverRan = false;

  void clearDlcDetailCache() => _dlcDetailCacheByKey.clear();

  /// One-time cleanup that runs before the first `listOrders()` after upgrade.
  ///
  /// Idempotent: re-entry checks both an in-memory flag and the persisted
  /// schema version. Safe to call from cubit init or any DLC route entry.
  Future<void> runDlcSchemaCutoverIfNeeded() async {
    if (_dlcSchemaCutoverRan) return;
    final env = await _environment();
    final stored = await _authStorage.getDlcSchemaVersion(env);
    if (stored >= _dlcSchemaVersion) {
      _dlcSchemaCutoverRan = true;
      return;
    }

    debugPrint(
      'DLC schema cutover: clearing legacy order/negotiation/idempotency caches '
      '(found v$stored, upgrading to v$_dlcSchemaVersion).',
    );
    try {
      await _orderStorage.clear(env);
    } catch (e) {
      debugPrint('DLC schema cutover: order storage clear failed: $e');
    }
    try {
      await _negotiationStorage.clear(env);
    } catch (e) {
      debugPrint('DLC schema cutover: negotiation storage clear failed: $e');
    }
    try {
      await _idempotencyStorage.clear(env);
    } catch (e) {
      debugPrint('DLC schema cutover: idempotency storage clear failed: $e');
    }
    _dlcDetailCacheByKey.clear();
    await _authStorage.setDlcSchemaVersion(env, _dlcSchemaVersion);
    _dlcSchemaCutoverRan = true;
  }


  Future<Environment> _environment() async =>
      (await _settingsRepository.fetch()).environment;

  Future<Environment> getAppEnvironment() async => _environment();

  Future<DlcWalletAuth?> getWalletAuth() async {
    return _authStorage.get(await _environment());
  }

  Future<List<DlcWalletAuth>> getAllWalletAuths() async {
    return _authStorage.getAll(await _environment());
  }

  Future<String?> getActiveWalletOriginId() async {
    return _authStorage.getActiveWalletOriginId(await _environment());
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
    final all = payload.whereType<Map<String, dynamic>>().toList();
    if (ApiServiceConstants.dlcShowExpiredInstruments) {
      return dlcSortInstrumentsLiveBeforeExpired(all);
    }
    return dlcLiveInstruments(all);
  }

  /// Mark-to-market (live) and settled PnL via coordinator simulation per position.
  Future<int?> estimateWalletPnlSats({
    required List<DlcOrderSummary> orders,
    required double btcUsdSpotUsd,
  }) async {
    if (await getWalletAuth() == null) return null;
    final spotOutcome = btcUsdSpotUsd.round();
    var total = 0;
    var counted = false;
    for (final order in dlcOrdersForWalletPnlEstimate(orders)) {
      final outcome = isDlcClosedOrder(order)
          ? dlcOracleOutcomeUsd(order)
          : spotOutcome;
      if (outcome == null) continue;
      final request = dlcOptionPayoutSimulationRequestForOrder(
        order,
        outcomePriceUsd: outcome,
      );
      if (request == null) continue;
      try {
        final result = await simulateOptionPayout(request);
        total += result.roundedPnlSats;
        counted = true;
      } catch (e) {
        debugPrint('DLC wallet PnL estimate skipped for ${order.orderId}: $e');
      }
    }
    return counted ? total : 0;
  }

  /// Calls `POST /orders/option-payout-simulation`.
  ///
  /// Uses the active wallet token when registered; otherwise calls without
  /// authorization so the simulate tab works before wallet activation.
  Future<DlcOptionPayoutSimulationResult> simulateOptionPayout(
    DlcOptionPayoutSimulationRequest request,
  ) async {
    final auth = await getWalletAuth();
    final raw = await _datasource.simulateOptionPayout(
      token: auth?.walletToken,
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
    final coordinatorXpub = await _localSigner.registrationXpubForCoordinator(
      wallet: wallet,
    );

    final noncePayload = await _datasource.createNonce();
    final nonce = noncePayload['nonce'] as String? ?? '';
    if (nonce.isEmpty) {
      throw Exception('Coordinator did not return nonce.');
    }

    final xpubSignature = await _localSigner.signXpubRegistrationProof(
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

    final registrationPayload = await _datasource.registerWallet(
      xpub: coordinatorXpub,
      nonce: nonce,
      xpubSignature: xpubSignature,
      label: wallet.label ?? 'Bull Wallet',
      utxos: utxoProofs,
    );

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

  /// Reconciles coordinator-visible UTXOs after funding or settlement broadcast
  /// projection (best-effort on the coordinator; wallet chain view is source of truth).
  Future<DlcWalletSyncResult?> syncActiveWalletUtxosAfterCoordinatorProjection({
    required List<DlcOrderSummary> currentOrders,
    required List<DlcOrderSummary> previousOrders,
  }) async {
    if (!dlcOrdersRequireUtxoSyncAfterProjection(
      current: currentOrders,
      previous: previousOrders,
    )) {
      return null;
    }
    return _trySyncActiveWalletUtxos();
  }

  Future<void> setActiveWalletOriginId(String walletOriginId) async {
    final env = await _environment();
    await _authStorage.setActiveWalletOriginId(env, walletOriginId);
  }

  Future<DlcOrderSummary> getOrder(String orderId) async {
    final auth = await getWalletAuth();
    if (auth == null) throw Exception('Wallet is not registered for DLC.');
    final env = await _environment();
    try {
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
      return _enrichOrderWithDlcIfNeeded(
        token: auth.walletToken,
        environment: env,
        auth: auth,
        order: order,
        coordinatorJson: json,
        forceRefresh: true,
      );
    } catch (e) {
      if (isCoordinatorResourceNotFound(e)) {
        await _purgeLocalCoordinatorSnapshot(
          environment: env,
          auth: auth,
          orderId: orderId,
        );
      }
      rethrow;
    }
  }

  /// Scans active-wallet orders and runs taker accept / maker sign when required.
  Future<DlcNegotiationPassResult> runNegotiationPass({
    String? focusOrderId,
  }) async {
    final auth = await getWalletAuth();
    if (auth == null) return DlcNegotiationPassResult.skipped();

    final env = await _environment();
    var orders = await listOrders(fetchDlcDetails: false);
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
        if (isCoordinatorResourceNotFound(e)) {
          await _purgeLocalCoordinatorSnapshot(
            environment: env,
            auth: auth,
            orderId: order.orderId,
            dlcId: order.dlcId,
          );
          continue;
        }
        if (isAcceptSigningNoLongerRequired(e)) {
          await _tryReconcileTakerAccept(
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
    final orders = await listOrders(fetchDlcDetails: false);
    return orders.any(needsDlcNegotiation);
  }

  Future<List<DlcOrderSummary>> listOrders({bool fetchDlcDetails = true}) async {
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
    final remoteRows = payload.whereType<Map<String, dynamic>>().toList();
    final mapped = remoteRows
        .map(
          (json) => _mapOrder(
            _mergeCoordinatorOrderJson(
              remote: json,
              local: localByOrderId[json['order_id']?.toString()],
            ),
          ),
        )
        .toList(growable: false);
    final merged = fetchDlcDetails
        ? await Future.wait(
            List.generate(mapped.length, (index) {
              return _enrichOrderWithDlcIfNeeded(
                token: auth.walletToken,
                environment: env,
                auth: auth,
                order: mapped[index],
                coordinatorJson: remoteRows[index],
              );
            }),
          )
        : mapped;
    for (final json in payload.whereType<Map<String, dynamic>>()) {
      await _persistOrderSnapshot(environment: env, auth: auth, values: json);
    }
    return _appendLocalOnlyOrders(
      environment: env,
      auth: auth,
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
      if (isCoordinatorResourceNotFound(e)) {
        await _purgeLocalCoordinatorSnapshot(
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
      final payload = await _createWithStaleBalanceRecovery(
        token: auth.walletToken,
        request: request,
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
      // Reconcile is best-effort: any failure here must not replace the
      // original create error, otherwise the user sees a misleading message
      // (e.g. "Exception: DLC API request failed" from a follow-up listOrders
      // network failure) while their order may actually be live.
      DlcOrderSummary? reconciled;
      try {
        reconciled = await _tryReconcileCreatedOrder(
          environment: env,
          auth: auth,
          draft: draft,
          draftFingerprint: draftFingerprint,
          funding: funding,
          idempotencyKey: idempotencyKey,
          error: e,
        );
      } catch (reconcileError) {
        debugPrint('DLC create order reconcile failed: $reconcileError');
        reconciled = null;
      }
      if (reconciled != null) {
        await _trySyncActiveWalletUtxos();
        return DlcCreateOrderResult(
          order: reconciled,
          syncBefore: syncBefore,
        );
      }
      final keepForReconcile =
          e is DlcApiException && e.statusCode == 409 ||
          _isTransientCoordinatorFailure(e);
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
      if (!_isTransientCoordinatorFailure(e)) rethrow;
      return _datasource.createOrder(token: token, payload: payload);
    }
  }

  /// Wraps the create POST with a single retry that first re-syncs the
  /// wallet's UTXO set with the coordinator. The coordinator's reserved
  /// balance can lag briefly after a match (the freshly matched order's
  /// funding inputs stay reserved until projection), causing a spurious
  /// `insufficient available balance` rejection when the wallet itself has
  /// enough funds. Re-syncing pushes the latest UTXOs / proofs and gives the
  /// coordinator a chance to re-evaluate before we surface the error.
  Future<Map<String, dynamic>> _createWithStaleBalanceRecovery({
    required String token,
    required Map<String, dynamic> request,
  }) async {
    try {
      return await _createOrderWithSingleTransientRetry(
        token: token,
        payload: request,
      );
    } catch (e) {
      if (!_isInsufficientCoordinatorBalanceError(e)) rethrow;
      debugPrint(
        'DLC create rejected with insufficient balance; re-syncing UTXOs and retrying once.',
      );
      try {
        await syncActiveWalletUtxos();
      } catch (syncError) {
        debugPrint(
          'DLC create: resync after insufficient balance failed: $syncError',
        );
        rethrow;
      }
      // Brief settle window so the coordinator's reservation bookkeeping
      // catches up with the fresh UTXO snapshot we just pushed.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      return _datasource.createOrder(token: token, payload: request);
    }
  }

  /// Coordinator-reported insufficient-balance signature (404/422-style with
  /// the matching message). Used to drive a single auto-recovery retry.
  bool _isInsufficientCoordinatorBalanceError(Object e) {
    final text = (e is DlcApiException ? e.message : e.toString())
        .toLowerCase();
    return text.contains('insufficient available balance') ||
        text.contains('insufficient balance') ||
        text.contains('not enough balance') ||
        text.contains('not enough available balance');
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

  /// Best-effort lookup of an order that may have been created on the
  /// coordinator after a transient client-side failure (timeout, dropped
  /// connection, secondary reconcile error). Resolves the same idempotency
  /// key the original create would have used so we find the exact order
  /// without relying on fuzzy draft matching. Network errors are swallowed
  /// — callers should treat null as "unknown" and rely on background polling.
  Future<DlcOrderSummary?> tryReconcileCreatedOrderByDraft(
    DlcOrderDraft draft,
  ) async {
    try {
      final auth = await getWalletAuth();
      if (auth == null) return null;
      final env = await _environment();
      final wallet = await _localSigner.getBitcoinWalletByOriginId(
        environment: env,
        walletOriginId: auth.walletOriginId,
      );
      final funding = draft.fundingPubkeyHex.isEmpty
          ? await _localSigner.deriveFundingPubkey(wallet: wallet)
          : DlcFundingPubkey(
              pubkeyHex: draft.fundingPubkeyHex,
              derivationPath: _localSigner.fundingDerivationPath(wallet),
            );
      final resolvedInstrumentId = _resolveCreateInstrumentId(draft);
      final draftFingerprint =
          '$resolvedInstrumentId|${draft.side.value}|${draft.quantity}|${draft.strikePrice}|${funding.pubkeyHex}';
      final idempotencyKey =
          await _idempotencyStorage.getOrCreateCreateDraftKey(
        environment: env,
        draftFingerprint: draftFingerprint,
      );
      final reconciled = await _reconcileCreateConflict(
        environment: env,
        auth: auth,
        idempotencyKey: idempotencyKey,
      );
      if (reconciled != null) {
        await _idempotencyStorage.clearCreateDraftKey(
          environment: env,
          draftFingerprint: draftFingerprint,
        );
      }
      return reconciled;
    } catch (e) {
      debugPrint('DLC reconcile-by-draft failed: $e');
      return null;
    }
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
        _isTransientCoordinatorFailure(error);
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
        'match_role': existing.matchRole,
        'is_maker': existing.isMaker,
        'executions': [
          for (final execution in existing.executions) execution.toJson(),
        ],
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
    if (ApiServiceConstants.dlcShowExpiredInstruments) return;
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

  /// Network failures where the coordinator may still have persisted the request.
  bool _isTransientCoordinatorFailure(Object e) {
    if (e is DlcApiException) {
      if (e.isTimeout || e.isConnectionError) return true;
      if (e.statusCode != null) return false;
      return isTransientDlcCoordinatorMessage(e.message);
    }
    return isTransientDlcCoordinatorMessage(e.toString());
  }

  Future<void> _trySyncActiveWalletUtxosForNegotiation() async {
    try {
      await syncActiveWalletUtxos();
    } catch (e) {
      if (!_isTransientCoordinatorFailure(e)) rethrow;
    }
  }

  Future<Map<String, dynamic>> _acceptContextWithTransientRetry({
    required String token,
    required String orderId,
    required String fundingPubkeyHex,
  }) async {
    try {
      return await _datasource.acceptContext(
        token: token,
        orderId: orderId,
        fundingPubkeyHex: fundingPubkeyHex,
      );
    } catch (e) {
      if (!_isTransientCoordinatorFailure(e)) rethrow;
      return _datasource.acceptContext(
        token: token,
        orderId: orderId,
        fundingPubkeyHex: fundingPubkeyHex,
      );
    }
  }

  Future<Map<String, dynamic>> _acceptMatchWithTransientRetry({
    required String token,
    required String orderId,
    required Map<String, dynamic> payload,
  }) async {
    try {
      return await _datasource.acceptMatch(
        token: token,
        orderId: orderId,
        payload: payload,
      );
    } catch (e) {
      if (!_isTransientCoordinatorFailure(e)) rethrow;
      return _datasource.acceptMatch(
        token: token,
        orderId: orderId,
        payload: payload,
      );
    }
  }

  Future<bool> _tryReconcileTakerAccept({
    required Environment environment,
    required DlcWalletAuth auth,
    required String orderId,
    String acceptContextFingerprint = '',
  }) async {
    try {
      final json = await _datasource.getOrder(
        token: auth.walletToken,
        orderId: orderId,
      );
      final local = await _orderStorage.getByOrderId(
        environment: environment,
        walletOriginId: auth.walletOriginId,
        orderId: orderId,
      );
      final merged = _mergeCoordinatorOrderJson(remote: json, local: local);
      final order = _mapOrder(merged);
      if (needsDlcTakerAccept(order)) return false;
      await _persistOrderSnapshot(
        environment: environment,
        auth: auth,
        values: merged,
      );
      await _negotiationStorage.upsertOrderState(
        environment: environment,
        walletOriginId: auth.walletOriginId,
        orderId: orderId,
        values: {'negotiation_status': 'accept_reconciled'},
      );
      await _idempotencyStorage.clearAllKeysForOrder(
        environment: environment,
        orderId: orderId,
      );
      if (acceptContextFingerprint.isNotEmpty) {
        await _idempotencyStorage.clearAcceptKey(
          environment: environment,
          orderId: orderId,
          contextFingerprint: acceptContextFingerprint,
        );
      }
      return true;
    } catch (_) {
      return false;
    }
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

    Future<DlcOrderSummary> readMerged({String? prevDlcId}) async {
      final json = await _datasource.getOrder(
        token: auth.walletToken,
        orderId: orderId,
      );
      final local = await _orderStorage.getByOrderId(
        environment: env,
        walletOriginId: auth.walletOriginId,
        orderId: orderId,
      );
      return _mapOrder(_mergeCoordinatorOrderJson(remote: json, local: local));
    }

    DlcOrderSummary current;
    try {
      current = await readMerged();
    } catch (e) {
      if (isCoordinatorResourceNotFound(e)) {
        await _purgeLocalCoordinatorSnapshot(
          environment: env,
          auth: auth,
          orderId: orderId,
        );
      }
      rethrow;
    }
    var steps = 0;

    while (steps < maxSteps) {
      steps += 1;
      try {
        current = await readMerged(prevDlcId: current.dlcId);
      } catch (e) {
        if (isCoordinatorResourceNotFound(e)) {
          await _purgeLocalCoordinatorSnapshot(
            environment: env,
            auth: auth,
            orderId: orderId,
            dlcId: current.dlcId,
          );
        }
        rethrow;
      }

      if (needsDlcTakerAccept(current)) {
        if (!isDlcTakerForAccept(current)) {
          // Maker side has nothing to do during the taker accept window.
          break;
        }
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
        if (!isDlcMakerForSign(current)) {
          break;
        }
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
          if (isCoordinatorResourceNotFound(e)) {
            await _purgeLocalCoordinatorSnapshot(
              environment: env,
              auth: auth,
              orderId: current.orderId,
              dlcId: current.dlcId,
            );
            rethrow;
          }
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

    try {
      current = await readMerged(prevDlcId: current.dlcId);
    } catch (e) {
      if (isCoordinatorResourceNotFound(e)) {
        await _purgeLocalCoordinatorSnapshot(
          environment: env,
          auth: auth,
          orderId: orderId,
          dlcId: current.dlcId,
        );
      }
      rethrow;
    }

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
        if (isCoordinatorResourceNotFound(e)) {
          await _purgeLocalCoordinatorSnapshot(
            environment: env,
            auth: auth,
            orderId: orderId,
            dlcId: current.dlcId,
          );
        } else {
          debugPrint('DLC settlement/detail fetch skipped: $e');
        }
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

  Future<DlcOrderSummary?> _fetchFreshOrderForNegotiation({
    required Environment environment,
    required DlcWalletAuth auth,
    required String orderId,
  }) async {
    try {
      final json = await _datasource.getOrder(
        token: auth.walletToken,
        orderId: orderId,
      );
      final local = await _orderStorage.getByOrderId(
        environment: environment,
        walletOriginId: auth.walletOriginId,
        orderId: orderId,
      );
      final merged = _mergeCoordinatorOrderJson(remote: json, local: local);
      await _persistOrderSnapshot(
        environment: environment,
        auth: auth,
        values: merged,
      );
      final mapped = _mapOrder(merged);
      return _enrichOrderWithDlcIfNeeded(
        token: auth.walletToken,
        environment: environment,
        auth: auth,
        order: mapped,
        coordinatorJson: merged,
        forceRefresh: true,
      );
    } catch (e) {
      if (isCoordinatorResourceNotFound(e)) {
        await _purgeLocalCoordinatorSnapshot(
          environment: environment,
          auth: auth,
          orderId: orderId,
        );
      }
      return null;
    }
  }

  Future<DlcNegotiationAction?> _negotiateOrderIfNeeded({
    required DlcWalletAuth auth,
    required DlcOrderSummary order,
  }) async {
    final env = await _environment();
    final current =
        await _fetchFreshOrderForNegotiation(
          environment: env,
          auth: auth,
          orderId: order.orderId,
        ) ??
        order;
    if (isDlcNegotiationComplete(current)) return null;

    final wallet = await _localSigner.getBitcoinWalletByOriginId(
      environment: env,
      walletOriginId: auth.walletOriginId,
    );
    final funding = await _resolveFundingPubkey(
      environment: env,
      auth: auth,
      wallet: wallet,
      orderId: current.orderId,
    );

    if (needsDlcTakerAccept(current)) {
      if (!isDlcTakerForAccept(current)) {
        // Coordinator marked the order as awaiting accept signing but the
        // latest execution role is `maker`. Treat as a pending-accept
        // notification only — never call /accept-context as a maker.
        return null;
      }
      await _submitAcceptArtifacts(
        environment: env,
        token: auth.walletToken,
        wallet: wallet,
        orderId: current.orderId,
        fundingPubkeyHex: funding.pubkeyHex,
      );
      return DlcNegotiationAction(
        kind: DlcNegotiationActionKind.takerAccept,
        orderId: current.orderId,
        dlcId: current.dlcId,
      );
    }

    if (needsDlcMakerSign(current) && current.dlcId != null) {
      if (!isDlcMakerForSign(current)) {
        return null;
      }
      await _submitMakerSignArtifacts(
        environment: env,
        token: auth.walletToken,
        wallet: wallet,
        dlcId: current.dlcId!,
        orderId: current.orderId,
        fundingPubkeyHex: funding.pubkeyHex,
      );
      return DlcNegotiationAction(
        kind: DlcNegotiationActionKind.makerSign,
        orderId: current.orderId,
        dlcId: current.dlcId,
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
    await _trySyncActiveWalletUtxosForNegotiation();
    final auth = await getWalletAuth();
    for (var attempt = 0; attempt < 2; attempt++) {
      final Map<String, dynamic> context;
      try {
        context = await _acceptContextWithTransientRetry(
          token: token,
          orderId: orderId,
          fundingPubkeyHex: fundingPubkeyHex,
        );
      } catch (e) {
        if (auth != null && isCoordinatorResourceNotFound(e)) {
          await _purgeLocalCoordinatorSnapshot(
            environment: environment,
            auth: auth,
            orderId: orderId,
          );
          return;
        }
        if (auth != null && isAcceptSigningNoLongerRequired(e)) {
          await _tryReconcileTakerAccept(
            environment: environment,
            auth: auth,
            orderId: orderId,
          );
          return;
        }
        rethrow;
      }
      final fingerprint = context['context_fingerprint'] as String? ?? '';
      final idempotencyKey =
          await _idempotencyStorage.getOrCreateAcceptKeyForFingerprint(
        environment: environment,
        orderId: orderId,
        contextFingerprint: fingerprint,
      );
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
      final walletUtxos = await _getWalletUtxosUsecase.execute(walletId: wallet.id);
      final signed = await _localSigner.signDlcContext(
        wallet: wallet,
        contextTag: 'accept',
        context: context,
        fundingPubkeyHex: fundingPubkeyHex,
        walletUtxos: walletUtxos,
      );
      try {
        final accepted = await _acceptMatchWithTransientRetry(
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
        if (auth != null) {
          final acceptedDlcId = accepted['dlc_id']?.toString();
          if (acceptedDlcId != null && acceptedDlcId.isNotEmpty) {
            _invalidateDlcDetailCache(
              walletId: auth.walletId,
              dlcId: acceptedDlcId,
            );
          }
        }
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
        if (auth != null && isCoordinatorResourceNotFound(e)) {
          await _purgeLocalCoordinatorSnapshot(
            environment: environment,
            auth: auth,
            orderId: orderId,
          );
          return;
        }
        if (auth != null &&
            (_isTransientCoordinatorFailure(e) ||
                isAcceptSigningNoLongerRequired(e))) {
          final reconciled = await _tryReconcileTakerAccept(
            environment: environment,
            auth: auth,
            orderId: orderId,
            acceptContextFingerprint: fingerprint,
          );
          if (reconciled) return;
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
    await _trySyncActiveWalletUtxosForNegotiation();
    for (var attempt = 0; attempt < 2; attempt++) {
      final Map<String, dynamic> signContext;
      try {
        signContext = await _datasource.signContext(
          token: token,
          dlcId: dlcId,
        );
      } catch (e) {
        if (auth != null && isCoordinatorResourceNotFound(e)) {
          await _purgeLocalCoordinatorSnapshot(
            environment: environment,
            auth: auth,
            orderId: orderId,
            dlcId: dlcId,
          );
          return;
        }
        rethrow;
      }
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
      final walletUtxos = await _getWalletUtxosUsecase.execute(walletId: wallet.id);
      final makerSigned = await _localSigner.signDlcContext(
        wallet: wallet,
        contextTag: 'sign',
        context: signContext,
        fundingPubkeyHex: fundingPubkeyHex,
        walletUtxos: walletUtxos,
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
        _invalidateDlcDetailCache(walletId: auth?.walletId, dlcId: dlcId);
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
        if (auth != null && isCoordinatorResourceNotFound(e)) {
          await _purgeLocalCoordinatorSnapshot(
            environment: environment,
            auth: auth,
            orderId: orderId,
            dlcId: dlcId,
          );
          return;
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

  String _dlcDetailCacheKey(DlcWalletAuth auth, String dlcId) =>
      '${auth.walletId}:$dlcId';

  void _invalidateDlcDetailCache({String? walletId, String? dlcId}) {
    if (walletId == null && dlcId == null) {
      _dlcDetailCacheByKey.clear();
      return;
    }
    final keysToRemove = _dlcDetailCacheByKey.keys.where((key) {
      final colon = key.indexOf(':');
      if (colon <= 0) return false;
      final keyWalletId = key.substring(0, colon);
      final keyDlcId = key.substring(colon + 1);
      if (walletId != null && keyWalletId != walletId) return false;
      if (dlcId != null && keyDlcId != dlcId) return false;
      return true;
    }).toList(growable: false);
    for (final key in keysToRemove) {
      _dlcDetailCacheByKey.remove(key);
    }
  }

  Future<DlcOrderSummary> _enrichOrderWithDlcIfNeeded({
    required String token,
    required Environment environment,
    required DlcWalletAuth auth,
    required DlcOrderSummary order,
    Map<String, dynamic>? coordinatorJson,
    bool forceRefresh = false,
  }) async {
    final dlcId = order.dlcId;
    if (dlcId == null || dlcId.isEmpty) return order;

    final cacheKey = _dlcDetailCacheKey(auth, dlcId);

    if (!forceRefresh &&
        coordinatorJson != null &&
        coordinatorOrderJsonSkipsDlcDetailFetch(coordinatorJson) &&
        !orderShouldFetchDlcDetail(order, forceRefresh: false)) {
      return _mergeOrderWithCachedDlcDetail(
        list: order,
        cacheKey: cacheKey,
        auth: auth,
        dlcId: dlcId,
      );
    }

    if (!orderShouldFetchDlcDetail(order, forceRefresh: forceRefresh)) {
      return _mergeOrderWithCachedDlcDetail(
        list: order,
        cacheKey: cacheKey,
        auth: auth,
        dlcId: dlcId,
      );
    }

    if (!forceRefresh) {
      final cached = _dlcDetailCacheByKey[cacheKey];
      if (cached != null && _isDlcDetailCacheUsable(order: order, cached: cached)) {
        return mergeListOrderWithDlcEnrichment(
          list: order,
          enriched: cached.order,
        );
      }
      if (cached != null) {
        _invalidateDlcDetailCache(walletId: auth.walletId, dlcId: dlcId);
      }
    }

    try {
      final detail = await _datasource.getDlc(token: token, dlcId: dlcId);
      final enriched = _mergeDlcDetailIntoOrder(order, detail);
      _dlcDetailCacheByKey[cacheKey] = _CachedDlcDetail(
        order: enriched,
        fetchedAt: DateTime.now().toUtc(),
        detailUpdatedAt: detail['updated_at']?.toString(),
      );
      return enriched;
    } catch (e) {
      if (isCoordinatorResourceNotFound(e)) {
        _invalidateDlcDetailCache(walletId: auth.walletId, dlcId: dlcId);
        await _purgeLocalCoordinatorSnapshot(
          environment: environment,
          auth: auth,
          orderId: order.orderId,
          dlcId: dlcId,
        );
      }
      return _mergeOrderWithCachedDlcDetail(
        list: order,
        cacheKey: cacheKey,
        auth: auth,
        dlcId: dlcId,
      );
    }
  }

  DlcOrderSummary _mergeOrderWithCachedDlcDetail({
    required DlcOrderSummary list,
    required String cacheKey,
    required DlcWalletAuth auth,
    required String dlcId,
  }) {
    final cached = _dlcDetailCacheByKey[cacheKey];
    if (cached == null) return list;
    if (listDlcSnapshotAheadOfCached(list: list, cached: cached.order)) {
      _invalidateDlcDetailCache(walletId: auth.walletId, dlcId: dlcId);
    }
    return mergeListOrderWithDlcEnrichment(list: list, enriched: cached.order);
  }

  bool _isDlcDetailCacheUsable({
    required DlcOrderSummary order,
    required _CachedDlcDetail cached,
  }) {
    if (listDlcSnapshotAheadOfCached(list: order, cached: cached.order)) {
      return false;
    }
    return isDlcDetailCacheFresh(
      fetchedAt: cached.fetchedAt,
      order: order,
      detailUpdatedAt: cached.detailUpdatedAt,
    );
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
        if (isCoordinatorResourceNotFound(e)) {
          await _purgeLocalCoordinatorSnapshot(
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
        await _purgeLocalCoordinatorSnapshot(
          environment: environment,
          auth: auth,
          orderId: order.orderId,
          dlcId: order.dlcId,
        );
        continue;
      }
      targets.add(order);
    }
    return targets;
  }

  Future<void> _purgeLocalCoordinatorSnapshot({
    required Environment environment,
    required DlcWalletAuth auth,
    String? orderId,
    String? dlcId,
  }) async {
    _invalidateDlcDetailCache(walletId: auth.walletId, dlcId: dlcId);
    final resolvedOrderId = orderId ??
        (dlcId == null
            ? null
            : await _orderStorage.orderIdForDlcId(
                environment: environment,
                walletOriginId: auth.walletOriginId,
                dlcId: dlcId,
              ));
    final resolvedDlcId = dlcId;

    if (resolvedOrderId != null && resolvedOrderId.isNotEmpty) {
      await _negotiationStorage.removeOrderState(
        environment: environment,
        walletOriginId: auth.walletOriginId,
        orderId: resolvedOrderId,
      );
      await _orderStorage.removeOrder(
        environment: environment,
        walletOriginId: auth.walletOriginId,
        orderId: resolvedOrderId,
      );
      await _idempotencyStorage.clearAllKeysForOrder(
        environment: environment,
        orderId: resolvedOrderId,
      );
    }

    if (resolvedDlcId != null && resolvedDlcId.isNotEmpty) {
      await _idempotencyStorage.clearAllKeysForDlc(
        environment: environment,
        dlcId: resolvedDlcId,
      );
    }
  }

  Future<List<DlcOrderSummary>> _appendLocalOnlyOrders({
    required Environment environment,
    required DlcWalletAuth auth,
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
        walletOriginId: auth.walletOriginId,
        orderId: orderId,
      )) {
        await _purgeLocalCoordinatorSnapshot(
          environment: environment,
          auth: auth,
          orderId: orderId,
          dlcId: json['dlc_id']?.toString(),
        );
        continue;
      }
      try {
        final fresh = await _datasource.getOrder(
          token: auth.walletToken,
          orderId: orderId,
        );
        localOnly.add(
          _mapOrder(
            _mergeCoordinatorOrderJson(remote: fresh, local: json),
          ),
        );
      } catch (e) {
        if (isCoordinatorResourceNotFound(e)) {
          await _purgeLocalCoordinatorSnapshot(
            environment: environment,
            auth: auth,
            orderId: orderId,
            dlcId: json['dlc_id']?.toString(),
          );
        }
      }
    }
    return [...remote, ...localOnly];
  }

  DlcOrderSummary _mergeSettlementAndDetail(
    DlcOrderSummary current,
    Map<String, dynamic> settlement,
    Map<String, dynamic> detail,
  ) {
    final merged = _mergeDlcDetailIntoOrder(current, detail);
    return merged.copyWith(
      dlcStatus: (settlement['status'] ?? merged.dlcStatus)?.toString(),
      settlementType: (settlement['settlement_type'] ?? merged.settlementType)
          ?.toString(),
      confirmationStatus:
          (detail['confirmation_status'] ?? merged.confirmationStatus)
              ?.toString(),
    );
  }

  DlcOrderSummary _mergeDlcDetailIntoOrder(
    DlcOrderSummary o,
    Map<String, dynamic> d,
  ) {
    return o.copyWith(
      dlcStatus: d['status']?.toString() ?? o.dlcStatus,
      settlementType: d['settlement_type']?.toString() ?? o.settlementType,
      sideCollateralSat: dlcSellerCollateralSats(
            json: d,
            side: o.side,
            quantity: o.quantity,
          ) ??
          o.sideCollateralSat,
      partnerFeeSat: _readNumber(d, [
            'partner_fee_sats',
            'partner_fee_sat',
            'partner_fee',
            'fees_paid_to_partner_sats',
            'fees_paid_to_partner',
          ]) ??
          o.partnerFeeSat,
      networkFeeSat: _readNumber(d, [
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
    // Coordinator response is authoritative for `executions[]` once present;
    // only fall back to a local snapshot's executions when remote omits the
    // field (older cache).
    if (remote['executions'] is! List && local['executions'] is List) {
      merged['executions'] = local['executions'];
    }
    if (remote['pending_match_accept'] != true &&
        local['pending_match_accept'] == true) {
      final remoteStatus = (remote['status'] as String?)?.toLowerCase();
      if (remoteStatus == 'pending_accept') {
        merged['pending_match_accept'] = true;
      }
    }
    return merged;
  }

  DlcOrderSummary _mapOrder(Map<String, dynamic> json) {
    final status = json['status'] as String? ?? 'unknown';
    final pendingMatchAccept = json['pending_match_accept'] as bool? ?? false;

    final executions = <DlcOrderExecution>[];
    final rawExecutions = json['executions'];
    if (rawExecutions is List) {
      for (final entry in rawExecutions) {
        final parsed = DlcOrderExecution.tryFromJson(entry);
        if (parsed != null) executions.add(parsed);
      }
    }

    final latest = executions.isNotEmpty ? executions.last : null;

    final topLevelDlcId = (json['dlc_id'] as String?)?.trim();
    final dlcId = (topLevelDlcId != null && topLevelDlcId.isNotEmpty)
        ? topLevelDlcId
        : latest?.dlcId;

    final dlcStatus =
        (json['dlc_status'] as String?) ?? latest?.dlcStatus;

    // Derive role from the latest execution. Older snapshots / coordinators
    // that have not rolled out the canonical-DLC `executions[]` yet still
    // carry `match_role` / `is_maker`; use them as the next fallback. As a
    // last resort, infer from per-wallet coordinator signals
    // (`pending_match_accept` always identifies the taker side, and
    // `sign_required` identifies the maker side once the DLC moves past
    // accept) so the UI and negotiation worker stay correct even when the
    // coordinator omits the explicit role fields for an active match.
    String? matchRoleRaw = latest?.role ??
        json['match_role'] as String? ??
        json['role'] as String?;
    bool? isMaker = json['is_maker'] as bool?;
    if (latest != null) {
      isMaker = latest.isMaker;
    } else {
      final role = matchRoleRaw?.toLowerCase();
      if (isMaker == null && role == 'maker') {
        isMaker = true;
      } else if (isMaker == null && role == 'taker') {
        isMaker = false;
      }
      if (matchRoleRaw == null || matchRoleRaw.isEmpty) {
        if (pendingMatchAccept) {
          matchRoleRaw = 'taker';
          isMaker ??= false;
        } else if (json['sign_required'] == true) {
          final orderStatus = status.toLowerCase();
          final dlcStatusLower = (json['dlc_status'] as String?)?.toLowerCase();
          if (orderStatus == 'filled' || dlcStatusLower == 'accepted') {
            matchRoleRaw = 'maker';
            isMaker ??= true;
          }
        }
      }
    }

    final qty = json['quantity'];
    final price = json['price'];
    final filledQty = json['filled_quantity'] ?? json['filled_qty'];
    final remainingQty = json['remaining_quantity'] ?? json['remaining_qty'];
    final side = json['side'] as String?;

    double? toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value.trim());
      return null;
    }

    final fundingTxid = (json['funding_txid'] as String?) ?? latest?.fundingTxid;
    final closingTxid = (json['closing_txid'] as String?) ?? latest?.closingTxid;
    final refundTxid = (json['refund_txid'] as String?) ?? latest?.refundTxid;
    final lastErrorReason =
        (json['last_error_reason'] as String?) ?? latest?.lastErrorReason;
    final lastErrorMessage =
        (json['last_error_message'] as String?) ?? latest?.lastErrorMessage;

    return DlcOrderSummary(
      orderId: json['order_id'] as String? ?? json['id'] as String? ?? '',
      dlcId: dlcId,
      status: status,
      pendingMatchAccept: pendingMatchAccept,
      isMaker: isMaker,
      matchRole: matchRoleRaw,
      signRequired: json['sign_required'] as bool?,
      dlcStatus: dlcStatus,
      settlementType: json['settlement_type'] as String?,
      confirmationStatus: json['confirmation_status'] as String?,
      instrumentId: json['instrument_id'] as String?,
      side: side,
      quantity: toDouble(qty),
      price: toDouble(price),
      filledQuantity: toDouble(filledQty),
      remainingQuantity: toDouble(remainingQty),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      sideCollateralSat: dlcSellerCollateralSats(
        json: json,
        side: side,
        quantity: toDouble(qty),
      ),
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
      lastErrorReason: lastErrorReason,
      lastErrorMessage: lastErrorMessage,
      oracleOutcomeValue: json['oracle_outcome_value'] as String?,
      fundingTxid: fundingTxid,
      closingTxid: closingTxid,
      refundTxid: refundTxid,
      // Draft offer hex is only meaningful while no execution exists.
      draftOfferObjectHex: executions.isEmpty
          ? (json['offer_object_hex'] as String?) ??
              (json['draft_offer_object_hex'] as String?)
          : null,
      executions: List<DlcOrderExecution>.unmodifiable(executions),
    );
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

class _CachedDlcDetail {
  const _CachedDlcDetail({
    required this.order,
    required this.fetchedAt,
    this.detailUpdatedAt,
  });

  final DlcOrderSummary order;
  final DateTime fetchedAt;
  final String? detailUpdatedAt;
}
