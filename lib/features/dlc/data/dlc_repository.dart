import 'package:bb_mobile/core/settings/data/settings_repository.dart';
import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/core/utils/bip32_derivation.dart';
import 'package:bb_mobile/features/dlc/data/dlc_api_datasource.dart';
import 'package:bb_mobile/features/dlc/data/dlc_auth_storage.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_local_signer.dart';
import 'package:bb_mobile/features/dlc/domain/dlc_models.dart';

class DlcRepository {
  final SettingsRepository _settingsRepository;
  final DlcApiDatasource _datasource;
  final DlcAuthStorage _authStorage;
  final DlcLocalSigner _localSigner;

  DlcRepository({
    required SettingsRepository settingsRepository,
    required DlcApiDatasource datasource,
    required DlcAuthStorage authStorage,
    required DlcLocalSigner localSigner,
  }) : _settingsRepository = settingsRepository,
       _datasource = datasource,
       _authStorage = authStorage,
       _localSigner = localSigner;

  Future<Environment> _environment() async =>
      (await _settingsRepository.fetch()).environment;

  Future<DlcWalletAuth?> getWalletAuth() async {
    return _authStorage.get(await _environment());
  }

  Future<List<Map<String, dynamic>>> listInstruments() async {
    final payload = await _datasource.listInstruments();
    return payload.whereType<Map<String, dynamic>>().toList();
  }

  Future<DlcWalletAuth> registerDefaultWallet() async {
    final env = await _environment();
    final wallet = await _localSigner.getDefaultBitcoinWallet(env);
    final coordinatorXpub = Bip32Derivation.getBip32Xpub(wallet.xpub).toBase58();

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
      throw lastError ?? Exception('Wallet registration failed: nonce signature invalid.');
    }

    final auth = DlcWalletAuth(
      walletId: registrationPayload['wallet_id'] as String,
      walletToken: registrationPayload['wallet_token'] as String,
      expiresAt: DateTime.tryParse(
        registrationPayload['expires_at'] as String? ?? '',
      ),
    );
    await _authStorage.store(env, auth);
    return auth;
  }

  Future<List<DlcOrderSummary>> listOrders() async {
    final auth = await getWalletAuth();
    if (auth == null) return [];
    final payload = await _datasource.listOrders(token: auth.walletToken);
    return payload
        .whereType<Map<String, dynamic>>()
        .map(_mapOrder)
        .toList(growable: false);
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
    final wallet = await _localSigner.getDefaultBitcoinWallet(env);
    final fundingPubkey = draft.fundingPubkeyHex.isEmpty
        ? await _localSigner.deriveFundingPubkeyHex(wallet: wallet)
        : draft.fundingPubkeyHex;
    final payload = await _datasource.createOrder(
      token: auth.walletToken,
      payload: {
        'instrument_id': draft.instrumentId,
        'side': draft.side.value,
        'quantity': draft.quantity,
        'price': draft.price,
        'funding_pubkey_hex': fundingPubkey,
        'idempotency_key': 'create-${DateTime.now().millisecondsSinceEpoch}',
      },
    );
    return _mapOrder(payload);
  }

  Future<DlcOrderSummary> fillAndProcessOrder({
    required String orderId,
  }) async {
    final auth = await getWalletAuth();
    if (auth == null) throw Exception('Wallet is not registered for DLC.');
    final env = await _environment();
    final wallet = await _localSigner.getDefaultBitcoinWallet(env);
    final fundingPubkey = await _localSigner.deriveFundingPubkeyHex(wallet: wallet);

    final order = await _datasource.getOrder(token: auth.walletToken, orderId: orderId);
    var summary = _mapOrder(order);

    if (summary.pendingMatchAccept) {
      final context = await _datasource.acceptContext(
        token: auth.walletToken,
        orderId: summary.orderId,
        fundingPubkeyHex: fundingPubkey,
      );
      final signed = await _localSigner.signDlcContext(
        wallet: wallet,
        contextTag: 'accept',
        context: context,
        fundingPubkeyHex: fundingPubkey,
      );
      await _datasource.acceptMatch(
        token: auth.walletToken,
        orderId: summary.orderId,
        payload: {
          'funding_pubkey_hex': signed.fundingPubkeyHex,
          'cet_adaptor_signatures_hex': signed.cetAdaptorSignaturesHex,
          'refund_signature_hex': signed.refundSignatureHex,
          'funding_signatures_hex': signed.fundingSignaturesHex,
          'idempotency_key': 'accept-${DateTime.now().millisecondsSinceEpoch}',
        },
      );
    }

    if (summary.dlcId != null) {
      final signContext = await _datasource.signContext(
        token: auth.walletToken,
        dlcId: summary.dlcId!,
      );
      final makerSigned = await _localSigner.signDlcContext(
        wallet: wallet,
        contextTag: 'sign',
        context: signContext,
        fundingPubkeyHex: fundingPubkey,
      );
      await _datasource.signDlc(
        token: auth.walletToken,
        dlcId: summary.dlcId!,
        payload: {
          'cet_adaptor_signatures_hex': makerSigned.cetAdaptorSignaturesHex,
          'refund_signature_hex': makerSigned.refundSignatureHex,
          'funding_signatures_hex': makerSigned.fundingSignaturesHex,
          'idempotency_key': 'sign-${DateTime.now().millisecondsSinceEpoch}',
        },
      );
    }

    final refreshed = await _datasource.getOrder(
      token: auth.walletToken,
      orderId: orderId,
    );
    summary = _mapOrder(refreshed);
    return summary;
  }

  DlcOrderSummary _mapOrder(Map<String, dynamic> json) {
    return DlcOrderSummary(
      orderId: json['order_id'] as String? ?? json['id'] as String? ?? '',
      dlcId: json['dlc_id'] as String?,
      status: json['status'] as String? ?? 'unknown',
      pendingMatchAccept: json['pending_match_accept'] as bool? ?? false,
      matchedOrderId: json['matched_order_id'] as String?,
      matchedDlcId: json['matched_dlc_id'] as String?,
    );
  }
}
