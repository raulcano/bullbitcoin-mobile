import 'package:bb_mobile/core/settings/data/settings_repository.dart';
import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/utils/bip32_derivation.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet.dart';
import 'package:bb_mobile/features/dlc/data/dlc_api_datasource.dart';
import 'package:bb_mobile/features/dlc/data/dlc_auth_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_idempotency_storage.dart';
import 'package:bb_mobile/features/dlc/data/dlc_order_storage.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_local_signer.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';
import 'package:flutter/foundation.dart';

class DlcRepository {
  final SettingsRepository _settingsRepository;
  final DlcApiDatasource _datasource;
  final DlcAuthStorage _authStorage;
  final DlcIdempotencyStorage _idempotencyStorage;
  final DlcOrderStorage _orderStorage;
  final DlcLocalSigner _localSigner;

  DlcRepository({
    required SettingsRepository settingsRepository,
    required DlcApiDatasource datasource,
    required DlcAuthStorage authStorage,
    required DlcIdempotencyStorage idempotencyStorage,
    required DlcOrderStorage orderStorage,
    required DlcLocalSigner localSigner,
  }) : _settingsRepository = settingsRepository,
       _datasource = datasource,
       _authStorage = authStorage,
       _idempotencyStorage = idempotencyStorage,
       _orderStorage = orderStorage,
       _localSigner = localSigner;

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
    await _authStorage.store(env, refreshed);
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
      await _authStorage.store(env, refreshed);
    }
    final active = await _authStorage.get(env);
    return (activeAuth: active, expiredWallets: expired);
  }

  Future<List<Map<String, dynamic>>> listInstruments() async {
    final payload = await _datasource.listInstruments();
    return payload.whereType<Map<String, dynamic>>().toList();
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
    Map<String, dynamic>? registrationPayload;
    Exception? lastError;

    for (final xpubSignature in signatureCandidates) {
      try {
        registrationPayload = await _datasource.registerWallet(
          xpub: coordinatorXpub,
          nonce: nonce,
          xpubSignature: xpubSignature,
          label: wallet.label ?? 'Bull Wallet',
          utxos: const [],
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
    try {
      await _datasource.refreshWalletBalance(
        token: auth.walletToken,
        walletId: auth.walletId,
      );
    } catch (e) {
      debugPrint('DLC refresh-balance after register skipped: $e');
    }
    return auth;
  }

  Future<void> setActiveWalletOriginId(String walletOriginId) async {
    final env = await _environment();
    await _authStorage.setActiveWalletOriginId(env, walletOriginId);
  }

  Future<List<DlcOrderSummary>> listOrders() async {
    final auth = await getWalletAuth();
    if (auth == null) return [];
    final env = await _environment();
    final payload = await _datasource.listOrders(token: auth.walletToken);
    final mapped = payload
        .whereType<Map<String, dynamic>>()
        .map(_mapOrder)
        .toList(growable: false);
    final merged = await Future.wait(
      mapped.map((o) => _mergeOrderWithDlcSnapshot(auth.walletToken, o)),
    );
    for (final json in payload.whereType<Map<String, dynamic>>()) {
      await _persistOrderSnapshot(environment: env, auth: auth, values: json);
    }
    return _appendLocalOnlyOrders(
      remote: merged,
      local: await _orderStorage.listForWallet(
        environment: env,
        walletOriginId: auth.walletOriginId,
      ),
    );
  }

  Future<DlcOrderSummary> cancelOrder(String orderId) async {
    final auth = await getWalletAuth();
    if (auth == null) throw Exception('Wallet is not registered for DLC.');
    final json = await _datasource.cancelOrder(
      token: auth.walletToken,
      orderId: orderId,
    );
    return _mapOrder(json);
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

  Future<DlcOrderSummary> createOrder(DlcOrderDraft draft) async {
    final auth = await getWalletAuth();
    if (auth == null) throw Exception('Wallet is not registered for DLC.');
    final env = await _environment();
    final wallet = await _localSigner.getBitcoinWalletByOriginId(
      environment: env,
      walletOriginId: auth.walletOriginId,
    );
    final fundingPubkey = draft.fundingPubkeyHex.isEmpty
        ? await _localSigner.deriveFundingPubkeyHex(wallet: wallet)
        : draft.fundingPubkeyHex;
    final resolvedInstrumentId = _resolveCreateInstrumentId(draft);
    final draftFingerprint =
        '$resolvedInstrumentId|${draft.side.value}|${draft.quantity}|${draft.price}|$fundingPubkey';
    final idempotencyKey = await _idempotencyStorage.getOrCreateCreateDraftKey(
      environment: env,
      draftFingerprint: draftFingerprint,
    );
    try {
      final payload = await _datasource.createOrder(
        token: auth.walletToken,
        payload: {
          'instrument_id': resolvedInstrumentId,
          'side': draft.side.value,
          'quantity': draft.quantity,
          'price': draft.price > 0 ? draft.price : null,
          'funding_pubkey_hex': fundingPubkey,
          'idempotency_key': idempotencyKey,
        },
      );
      await _persistOrderSnapshot(
        environment: env,
        auth: auth,
        values: {
          ...payload,
          'idempotency_key': idempotencyKey,
          'funding_pubkey_hex': fundingPubkey,
          'funding_pubkey_derivation': 'wallet_external_0_0',
        },
      );
      await _idempotencyStorage.clearCreateDraftKey(
        environment: env,
        draftFingerprint: draftFingerprint,
      );
      return _mapOrder(payload);
    } catch (e) {
      final msg = e.toString().toLowerCase();
      final isTimeout = msg.contains('timeout') || msg.contains('timed out');
      if (!isTimeout) {
        await _idempotencyStorage.clearCreateDraftKey(
          environment: env,
          draftFingerprint: draftFingerprint,
        );
      }
      rethrow;
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

      if (_needsTakerAccept(current)) {
        await _submitAcceptArtifacts(
          environment: env,
          token: auth.walletToken,
          wallet: wallet,
          orderId: current.orderId,
          fundingPubkeyHex: fundingPubkey,
        );
        continue;
      }

      if (_needsMakerSign(current)) {
        try {
          await _submitMakerSignArtifacts(
            environment: env,
            token: auth.walletToken,
            wallet: wallet,
            dlcId: current.dlcId!,
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

    return current;
  }

  /// Same as [progressOrderLifecycle] — kept for call sites that used the old name.
  Future<DlcOrderSummary> fillAndProcessOrder({required String orderId}) async {
    return progressOrderLifecycle(orderId: orderId, maxSteps: 8);
  }

  Future<void> _submitAcceptArtifacts({
    required Environment environment,
    required String token,
    required Wallet wallet,
    required String orderId,
    required String fundingPubkeyHex,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final context = await _datasource.acceptContext(
        token: token,
        orderId: orderId,
        fundingPubkeyHex: fundingPubkeyHex,
      );
      final fingerprint = context['context_fingerprint'] as String? ?? '';
      final idempotencyKey = await _idempotencyStorage.getOrCreateAcceptKey(
        environment: environment,
        orderId: orderId,
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
        }
        await _idempotencyStorage.clearAcceptKey(
          environment: environment,
          orderId: orderId,
        );
        return;
      } catch (e) {
        if (_isContextMismatch(e) && attempt == 0) {
          await _idempotencyStorage.rotateAcceptKey(
            environment: environment,
            orderId: orderId,
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
    required String fundingPubkeyHex,
  }) async {
    final idempotencyKey = await _idempotencyStorage.getOrCreateSignKey(
      environment: environment,
      dlcId: dlcId,
    );
    final signContext = await _datasource.signContext(
      token: token,
      dlcId: dlcId,
    );
    final makerSigned = await _localSigner.signDlcContext(
      wallet: wallet,
      contextTag: 'sign',
      context: signContext,
      fundingPubkeyHex: fundingPubkeyHex,
    );
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
    final auth = await getWalletAuth();
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
    }
    await _idempotencyStorage.clearSignKey(
      environment: environment,
      dlcId: dlcId,
    );
  }

  bool _isContextMismatch(Object e) {
    final m = e.toString().toLowerCase();
    return m.contains('context_mismatch') || m.contains('stale_context');
  }

  bool _needsTakerAccept(DlcOrderSummary current) {
    if (current.pendingMatchAccept) return true;
    final s = current.status.toLowerCase();
    return s == 'pending_accept';
  }

  bool _needsMakerSign(DlcOrderSummary current) {
    if (current.dlcId == null) return false;
    if (current.signRequired != true) return false;
    final maker = current.isMaker;
    if (maker == true) return true;
    final role = current.matchRole?.toLowerCase();
    return role == 'maker';
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

  List<DlcOrderSummary> _appendLocalOnlyOrders({
    required List<DlcOrderSummary> remote,
    required List<Map<String, dynamic>> local,
  }) {
    final remoteIds = remote.map((o) => o.orderId).toSet();
    final localOnly = local
        .where((json) {
          final orderId = json['order_id']?.toString();
          return orderId != null &&
              orderId.isNotEmpty &&
              !remoteIds.contains(orderId);
        })
        .map(_mapOrder)
        .toList(growable: false);
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

  DlcOrderSummary _mapOrder(Map<String, dynamic> json) {
    final status = json['status'] as String? ?? 'unknown';
    final statusLower = status.toLowerCase();
    final pendingFromCreate = json['pending_match_accept'] as bool? ?? false;
    final pendingMatchAccept =
        pendingFromCreate || statusLower == 'pending_accept';

    bool? isMaker = json['is_maker'] as bool?;
    final role = (json['match_role'] as String?)?.toLowerCase();
    if (isMaker == null && role == 'maker') {
      isMaker = true;
    } else if (isMaker == null && role == 'taker') {
      isMaker = false;
    }

    final qty = json['quantity'];
    final price = json['price'];

    return DlcOrderSummary(
      orderId: json['order_id'] as String? ?? json['id'] as String? ?? '',
      dlcId: json['dlc_id'] as String?,
      status: status,
      pendingMatchAccept: pendingMatchAccept,
      matchedOrderId: json['matched_order_id'] as String?,
      matchedDlcId: json['matched_dlc_id'] as String?,
      isMaker: isMaker,
      matchRole: json['match_role'] as String?,
      signRequired: json['sign_required'] as bool?,
      dlcStatus: json['dlc_status'] as String?,
      settlementType: json['settlement_type'] as String?,
      confirmationStatus: json['confirmation_status'] as String?,
      instrumentId: json['instrument_id'] as String?,
      side: json['side'] as String?,
      quantity: qty is num ? qty.toDouble() : null,
      price: price is num ? price.toDouble() : null,
      lastErrorReason: json['last_error_reason'] as String?,
      lastErrorMessage: json['last_error_message'] as String?,
      oracleOutcomeValue: json['oracle_outcome_value'] as String?,
      fundingTxid: json['funding_txid'] as String?,
      closingTxid: json['closing_txid'] as String?,
      refundTxid: json['refund_txid'] as String?,
    );
  }

  String _resolveCreateInstrumentId(DlcOrderDraft draft) {
    final templateId = draft.instrumentId.trim();
    if (!templateId.contains('-STRIKE-')) {
      return templateId;
    }
    if (draft.price <= 0) {
      throw Exception('Strike price is required for STRIKE instruments');
    }
    final strike = _normalizeStrikeToken(draft.price);
    return templateId.replaceFirst('-STRIKE-', '-$strike-');
  }

  String _normalizeStrikeToken(double strike) {
    final rounded = strike.roundToDouble();
    if ((strike - rounded).abs() < 1e-9) {
      return rounded.toInt().toString();
    }
    return strike.toStringAsFixed(8).replaceFirst(RegExp(r'\.?0+$'), '');
  }
}
