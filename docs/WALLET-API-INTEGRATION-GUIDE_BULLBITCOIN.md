# Wallet API Integration Guide

This guide describes how a wallet client integrates with the DLC Coordinator API from initial setup through wallet registration, order creation, DLC negotiation, funding, oracle settlement monitoring, and post-settlement wallet sync.

It is intentionally client-agnostic. The same flow applies to a mobile wallet, desktop wallet, custody platform, server-side wallet service, or embedded wallet SDK, as long as the client can:

- discover wallet UTXOs,
- derive and persist public keys,
- sign messages and transaction sighashes locally,
- create ECDSA adaptor signatures for DLC CETs,
- store local integration state durably,
- call the coordinator over HTTP.

The coordinator never needs wallet seed material, private keys, xprivs, signing secrets, or raw wallet credentials.

> **About this document:** Sections above describe the client-agnostic integration contract. Throughout the guide, **"How we did this in BullBitcoin"** subsections document the concrete Flutter implementation in `lib/features/dlc/` of the Bull Bitcoin mobile wallet. Where BullBitcoin has not yet wired an endpoint, that is stated explicitly so gaps are visible alongside the target integration.

## Source Of Truth

Use this guide as the implementation map, and use the live OpenAPI schema as the exact request and response contract for the deployed environment:

```text
GET /openapi.json
GET /docs
GET /redoc
```

The most relevant source documents are:

- [API Reference](API-REFERENCE.md)
- [Wallet UTXO Sync And Refresh](WALLET-UTXO-SYNC.md)
- [Wallet DLC Automation](WALLET-DLC-AUTOMATION.md)
- [Wallet Option Payout Simulation](WALLET-OPTION-PAYOUT-SIMULATION.md)
- [End-to-End Walkthrough Guide](END-TO-END-WALKTHROUGH-GUIDE.md)

The OpenAPI schema wins over examples in this guide if an environment is newer than the checked-in documentation.

## Integration Boundary

The coordinator is the DLC protocol coordinator and order matching service. The wallet client is the key owner and local signing authority.

The coordinator does:

- authenticate registered wallets,
- validate partner access where required,
- store wallet-visible UTXO state,
- validate UTXO liveness,
- reserve funding inputs for active orders and DLCs,
- build canonical `OfferDLCMessage`, `AcceptDLCMessage`, and `SignDLCMessage` payloads,
- provide signing contexts,
- validate submitted signature artifacts,
- build and broadcast the funding transaction after the maker sign step,
- track DLC funding, oracle, settlement, and confirmation state.

The wallet client does:

- keep all private key material local,
- derive wallet xpubs and public keys,
- sign wallet registration and UTXO ownership proofs,
- choose which UTXOs the coordinator may use,
- derive or select DLC funding keypairs,
- sign coordinator-provided accept and sign contexts,
- submit only signature artifacts and public data,
- track local order/DLC state for retries and crash recovery,
- display status, risk, funding, settlement, and error information to the user.

The wallet must treat coordinator-returned `offer_object_hex`, `accept_object_hex`, and `sign_object_hex` as the canonical DLC protocol messages. The wallet should not construct replacement DLC messages locally.

### How we did this in BullBitcoin

The mobile app implements the wallet side entirely inside `lib/features/dlc/`, wired through GetIt in `DlcLocator.setup()`. The coordinator never receives seed material; all signing stays in `DlcLocalSigner`, which reads keys from `SeedRepository` by wallet master fingerprint.

| Layer | Location | Responsibility |
| --- | --- | --- |
| DI / HTTP | `lib/features/dlc/dlc_locator.dart` | Registers a dedicated `Dio` instance (`dlcCoordinatorDio`), API datasource, secure storage, signer, repository, and cubit |
| Data | `lib/features/dlc/data/` | `DlcApiDatasource` (HTTP), `DlcRepository` (orchestration), secure storage helpers |
| Domain | `lib/features/dlc/domain/` | Models, local signing, negotiation/order/instrument utilities, background signing isolate |
| Presentation | `lib/features/dlc/presentation/` | `DlcCubit` + `DlcState` (flutter_bloc) |
| UI | `lib/features/dlc/ui/` | `DlcRouter` mounts `DlcHomeScreen` at route `/dlcs` |

`DlcRepository` is the single integration authority: it calls the coordinator, merges remote order JSON with local snapshots, runs the negotiation worker (taker accept / maker sign), and caches DLC detail. The UI never talks to `Dio` directly.

Only on-chain Bitcoin wallets are eligible (`Wallet.isBitcoin && !Wallet.isLiquid`). Liquid wallets are excluded from registration and trading.

## Required Configuration

Every wallet integration needs environment-specific configuration:

| Setting | Purpose |
| --- | --- |
| Coordinator base URL | HTTP origin for the target coordinator deployment. |
| Expected Bitcoin network | `regtest`, `testnet3`, or `mainnet`, depending on deployment. |
| Partner id | The partner identifier assigned by the coordinator operator. |
| Partner token | Secret sent as `X-Partner-Token` to partner-protected endpoints. |
| Request timeout policy | Long enough for DLC context generation and signature submission responses. |
| Retry policy | Idempotent retries for create, accept, and sign operations. |
| Key derivation policy | How the wallet derives xpubs, DLC funding keys, payout keys, and signing keys. |
| Local persistence policy | Where wallet tokens, order ids, DLC ids, key paths, fingerprints, and retries are stored. |

The partner token is application configuration. Do not expose it as a normal user-editable field. Treat it like an API credential.

### How we did this in BullBitcoin

Configuration lives in `.env`, loaded at startup via `flutter_dotenv` into `ApiServiceConstants` (`lib/core/utils/constants.dart`):

| Env variable | Constant | Purpose |
| --- | --- | --- |
| `DLC_COORDINATOR_URL` | `dlcCoordinatorBaseUrl` | Mainnet coordinator origin (default `http://localhost:8000`) |
| `DLC_COORDINATOR_BACKUP_URL` | `dlcCoordinatorBackupBaseUrl` | Failover origin for read/time-out paths |
| `DLC_COORDINATOR_TEST_URL` | `dlcCoordinatorTestBaseUrl` | Testnet coordinator (falls back to mainnet URL) |
| `DLC_COORDINATOR_TEST_BACKUP_URL` | `dlcCoordinatorTestBackupBaseUrl` | Testnet backup |
| `DLC_COORDINATOR_PARTNER_ID` | `dlcCoordinatorPartnerId` | Stored on local order snapshots as `partner_id` |
| `DLC_COORDINATOR_PARTNER_TOKEN` | `dlcCoordinatorPartnerToken` | Sent on every coordinator request as `X-Partner-Token` |
| `DLC_BTC_USD_TICKER_URL` | `dlcBtcUsdTickerUrl` | External spot price for strike suggestions (Coinbase BTC-USD by default) |
| `DLC_DEFAULT_PREMIUM_SATOSHIS_PER_CONTRACT` | `dlcDefaultPremiumPerContractSatoshis` | UI default premium input |
| `DLC_SHOW_EXPIRED_INSTRUMENTS` | `dlcShowExpiredInstruments` | Dev flag: `GET /instruments` instead of `/instruments/non-expired` |

The active coordinator URL follows the app environment setting (`SettingsRepository`): `ApiServiceConstants.dlcCoordinatorUrlForEnvironment()` picks mainnet vs testnet. The partner token is build-time configuration only — it is not exposed in settings UI.

HTTP timeouts on the shared `Dio` instance are 8 seconds connect/receive/send. Write operations (create order, accept, sign) override to 90 s receive / 30 s send via `_coordinatorWriteOptions()` in `DlcApiDatasource`.

## Authentication Headers

Most wallet-owned endpoints require:

```text
Authorization: Bearer <wallet_token>
```

The wallet token is returned by wallet registration.

Partner-protected endpoints require:

```text
X-Partner-Token: <partner_token>
```

At minimum, expect the partner token to be required for:

- wallet registration,
- partner configuration,
- order creation,
- accept context and accept submission,
- maker sign submission,
- option payout simulation.

Some read endpoints only require the wallet bearer token. Use the live OpenAPI schema for the exact header set of the deployed coordinator.

### How we did this in BullBitcoin

`DlcLocator` registers a dedicated `Dio` client with `persistentConnection: false` to avoid a known Uvicorn/httptools issue where back-to-back POSTs on a keep-alive connection produce "Invalid HTTP request received".

Partner authentication is applied globally: if `DLC_COORDINATOR_PARTNER_TOKEN` is non-empty, a request interceptor adds `X-Partner-Token` to **every** coordinator call, including unauthenticated routes like `POST /auth/nonce`.

Wallet bearer tokens are added per call in `DlcApiDatasource` methods that require them (`Authorization: Bearer <wallet_token>`). The token comes from `DlcAuthStorage`, populated at registration.

For resilience, `DlcApiDatasource` installs an error interceptor that retries once against `dlcCoordinatorBackupUrlForEnvironment()` on timeout, connection error, or unknown errors. Write paths set `extra['dlc_skip_backup'] = true` so a slow accept/sign is not silently retried against a different host mid-flight.

## End-To-End Flow Summary

The complete happy path is:

```text
1. Configure coordinator base URL, network, partner id, and partner token.
2. Check coordinator readiness.
3. Check partner configuration.
4. Register the wallet and store wallet_token.
5. Sync current wallet UTXOs.
6. Discover non-expired instruments.
7. Optionally simulate payout and show estimated economics.
8. Optionally fetch the orderbook.
9. Derive a DLC funding public key.
10. Create an order.
11. If the order rests, monitor it.
12. If the order matches as taker, fetch accept context.
13. Sign accept context locally.
14. Submit accept artifacts.
15. If the wallet is maker and sign_required becomes true, fetch sign context.
16. Sign sign context locally.
17. Submit sign artifacts.
18. Monitor funding transaction broadcast and confirmation status.
19. Monitor oracle maturity, attestation, settlement, and confirmation status.
20. Sync wallet UTXOs after funding, cancellation, settlement, refund, or external wallet activity.
```

### How we did this in BullBitcoin

The happy path above maps to these entry points in the Flutter app:

1. **Configure** — `.env` + `DlcLocator` (see Required Configuration).
2. **Readiness** — `DlcCubit._loadCatalog()` / `_reloadActiveWalletData()` → `DlcRepository.getSystemReadiness()`.
3. **Partner config** — not fetched; partner token validity is inferred from HTTP 403 responses at order time.
4. **Register** — `DlcCubit.registerWallet()` → `DlcRepository.registerWalletByOriginId()`.
5. **Sync UTXOs** — `DlcRepository.syncActiveWalletUtxos()` on wallet activation and before every trade.
6. **Instruments** — `DlcRepository.listInstruments()` on catalog load.
7. **Simulate** — Simulate tab → `DlcRepository.simulateOptionPayout()`.
8. **Orderbook** — `DlcCubit._fetchStrikeOrderbooks()` → `GET /orderbook/{instrument_id}` per strike.
9. **Funding key** — `DlcLocalSigner.deriveFundingPubkey()` at `{wallet.derivationPath}/0/0`.
10. **Create order** — `DlcCubit.createOrder()` (optimistic UI) → background `_completeCreateOrderInBackground()` → `DlcRepository.createOrder()`.
11. **Negotiation** — `DlcCubit._runNegotiationWorker()` → `DlcRepository.runNegotiationPass()` handles taker accept and maker sign automatically.
12. **Monitor** — 15-second background poll refreshes orders and enriches DLC detail/settlement fields.
13. **Resume** — local snapshots in secure storage (`DlcOrderStorage`, `DlcNegotiationStorage`, `DlcIdempotencyStorage`) survive app restarts.

## Step 1: Check Coordinator Readiness

Call readiness before enabling the feature or submitting orders:

```text
GET /auth/system-readiness
```

Typical response fields:

```json
{
  "network": "testnet3",
  "is_regtest": false,
  "trading_ready": true,
  "can_create_funded_wallet": false,
  "blockers": [],
  "chain_backend": {
    "ok": true,
    "latency_ms": 12,
    "error": null,
    "details": {
      "source": "bitcoinlib providers.json",
      "provider": "electrumx.testnet3",
      "provider_type": "electrumx",
      "provider_network": "testnet"
    }
  },
  "regtest_mining": null
}
```

Do not rely on legacy `bitcoin_node` or `electrumx` keys. Use `trading_ready` and `chain_backend.ok` for trading health; use `network` for environment matching. Treat `regtest_mining` as optional and regtest-only (demo funding), not as the runtime chain dependency.

Client requirements:

- verify the coordinator is reachable,
- verify the environment matches the coordinator `network`,
- disable trading if critical blockers are present or `trading_ready` is false,
- show degraded status if `chain_backend` is unavailable,
- use environment-specific messaging for test deployments.

The readiness response does not replace wallet-side network checks. A wallet must still ensure that its own keys, UTXOs, addresses, and transactions belong to the same Bitcoin network as the coordinator.

### How we did this in BullBitcoin

On every catalog load and full wallet reload, `DlcCubit` calls `DlcRepository.getSystemReadiness()` → `GET /auth/system-readiness`. Failures are non-fatal: `coordinatorReadinessFailed` is set and the feature still loads instruments, but a banner is shown.

`DlcCubit._buildCoordinatorTradingHint()` composes user-visible warnings from the readiness payload:

- missing `DLC_COORDINATOR_PARTNER_TOKEN`,
- `trading_ready` false or unhealthy `chain_backend`,
- non-empty `blockers` list,
- regtest coordinator while the app environment is mainnet,
- mismatch between coordinator `network` and app environment (mainnet vs testnet).

The hint is rendered at the top of `DlcHomeScreen` when non-null. Readiness does not hard-disable the feature, but order creation surfaces explicit 403/401 errors if configuration is wrong.

## Step 2: Check Partner Configuration

Call:

```text
GET /partners/{partner_id}/config
X-Partner-Token: <partner_token>
```

Typical response fields:

```json
{
  "id": "partner-id",
  "name": "Partner Name",
  "slug": "partner-slug",
  "thumbnail_url": "",
  "xpub": "",
  "relative_fee_maker": 0.0,
  "relative_fee_taker": 0.0,
  "absolute_fee_maker": 0,
  "absolute_fee_taker": 0,
  "premium_paid_upfront": false,
  "token_id": "token-id",
  "token_valid": true,
  "token_expires_at": "2026-06-01T00:00:00Z",
  "token_created_at": "2026-05-01T00:00:00Z",
  "last_updated_at": "2026-05-01T00:00:00Z"
}
```

Client requirements:

- verify `token_valid == true`,
- persist or cache fee and premium-mode fields for display,
- refresh this config when the app starts and before order creation,
- disable order creation if the token is invalid, expired, or does not match the configured partner id.

The coordinator uses the partner configuration to compute partner wallet fees and premium treatment. The client should display estimates but must let the coordinator compute final order economics.

### How we did this in BullBitcoin

**Not implemented.** The app does not call `GET /partners/{partner_id}/config`. Partner identity is limited to:

- `DLC_COORDINATOR_PARTNER_ID` stored on local order snapshots (`partner_id` field in `_createdOrderSnapshot()`),
- `DLC_COORDINATOR_PARTNER_TOKEN` attached to every HTTP request.

Fee and premium-mode fields from partner config are not cached locally. Instead:

- payout simulation (`POST /orders/option-payout-simulation`) returns coordinator-computed partner fees, which the Simulate tab and PnL estimation consume,
- order detail enrichment reads `partner_fee_sats` (and aliases) from coordinator order/DLC JSON when present.

Invalid or missing partner tokens surface as HTTP 403 on protected endpoints. `DlcCubit.createOrder()` maps 403 responses containing "partner" or "x-partner-token" to a user-facing configuration error.

## Step 3: Register A Wallet

Wallet registration gives the coordinator a wallet identity, initial UTXO set, and wallet bearer token. Registration is also the first UTXO sync.

### 3.1 Request A Nonce

```text
POST /auth/nonce
Content-Type: application/json
```

Request:

```json
{}
```

Response:

```json
{
  "nonce": "<nonce>",
  "expires_at": "2026-05-19T12:00:00Z"
}
```

Use the nonce to bind wallet ownership proofs to a short-lived challenge.

### 3.2 Optionally Validate The Nonce

```text
GET /auth/nonce/{nonce}
```

Response:

```json
{
  "valid": true,
  "message": "..."
}
```

This is a convenience read. Registration itself also validates the nonce.

### 3.3 Build Wallet Ownership Proofs

The wallet client prepares:

- `xpub`: an extended public key for the wallet account or integration scope,
- `xpub_signature`: a signature proving control of the xpub using the nonce,
- `label`: a wallet display label,
- `utxos`: the current wallet-selected UTXOs that the coordinator may consider,
- one UTXO ownership signature per submitted UTXO when validation is enabled.

Each UTXO entry uses:

```json
{
  "txid": "<txid>",
  "vout": 0,
  "signature": "<signature proving ownership of this UTXO>",
  "public_key": "<hex public key controlling this UTXO>"
}
```

The client decides which UTXOs to expose. It may omit UTXOs reserved for other activity. The coordinator should only consider client-declared and validated UTXOs as available for DLC funding.

### 3.4 Submit Wallet Registration

```text
POST /auth/wallet
Authorization: not required
X-Partner-Token: <partner_token>
Content-Type: application/json
```

Request:

```json
{
  "xpub": "<wallet xpub>",
  "xpub_signature": "<signature over nonce/xpub registration material>",
  "nonce": "<nonce>",
  "label": "Primary Wallet",
  "utxos": [
    {
      "txid": "<txid>",
      "vout": 0,
      "signature": "<utxo ownership signature>",
      "public_key": "<hex public key>"
    }
  ]
}
```

Response:

```json
{
  "wallet_id": "<wallet id>",
  "wallet_token": "<wallet bearer token>",
  "expires_at": "2026-06-18T12:00:00Z"
}
```

Client requirements:

- store `wallet_id`, `wallet_token`, `expires_at`, partner id, network, xpub reference, and local wallet/account reference,
- store them in the wallet's secure storage or account metadata system,
- never store the partner token in ordinary user data,
- refresh or re-register before `wallet_token` expires,
- support multiple registered wallets if the wallet product supports multiple accounts,
- scope all orders and DLCs to the active registered wallet.

### How we did this in BullBitcoin

Registration is triggered from the DLC home screen wallet picker via `DlcCubit.registerWallet()` → `DlcRepository.registerWalletByOriginId(walletOriginId)`.

**3.1 Nonce** — `DlcApiDatasource.createNonce()` → `POST /auth/nonce`. The optional `GET /auth/nonce/{nonce}` validation endpoint is not used; registration validates the nonce implicitly.

**3.2 Xpub** — The coordinator receives a BIP32 xpub in base58: `Bip32Derivation.getBip32Xpub(wallet.xpub).toBase58()`. Only the user's selected on-chain Bitcoin wallet is eligible.

**3.3 Ownership proofs** — `DlcLocalSigner.signNonceProofCandidates()` tries multiple digest/key variants because coordinator deployments may expect different nonce-binding formats:

- account-level key at `wallet.derivationPath`,
- interaction/funding key at `{wallet.derivationPath}/0/0`,
- raw nonce UTF-8 vs hex-encoded nonce,
- single SHA256 vs double SHA256.

The loop in `registerWalletByOriginId()` submits each candidate until registration succeeds or a non-signature error is returned.

**3.4 UTXO proofs** — `GetWalletUtxosUsecase` loads local UTXOs; `DlcLocalSigner.buildUtxoProofs()` signs `SHA256(txid + vout + nonce)` with the per-UTXO private key and emits `{ txid, vout, signature (DER + sighash byte), public_key }`.

**3.5 Persist auth** — Response fields map to `DlcWalletAuth` and are stored in secure storage via `DlcAuthStorage.store()`:

```dart
DlcWalletAuth(
  walletOriginId: wallet.id,       // local Bull wallet id
  walletLabel: wallet.label,
  walletXpub: coordinatorXpub,
  walletId: payload['wallet_id'],
  walletToken: payload['wallet_token'],
  expiresAt: DateTime.parse(payload['expires_at']),
)
```

Storage is partitioned by environment (`dlc_wallet_auth_mainnet` / `dlc_wallet_auth_testnet`). Multiple wallets can be registered; `activeWalletOriginId` tracks the session wallet. Switching wallets calls `setActiveWalletOriginId()` without re-registering.

Token refresh: `validateStoredWalletAuth()` and `validateAndLoadWalletAuths()` call `GET /auth/wallet/{wallet_id}` on load. A 401/403/404 clears storage and surfaces `DlcExpiredWalletInfo` in UI state. Re-registration is manual from the wallet picker.

## Step 4: Read Wallet State

Call:

```text
GET /auth/wallet/{wallet_id}
Authorization: Bearer <wallet_token>
```

Typical response fields:

```json
{
  "wallet_id": "<wallet id>",
  "xpub": "<wallet xpub>",
  "utxos": [],
  "available_balance": 100000,
  "total_balance": 150000,
  "reserved_balance": 50000,
  "warning": null,
  "last_utxo_sync_at": "2026-05-19T12:00:00Z",
  "utxo_sync_status": "ok",
  "utxo_sync_error": null,
  "utxo_sync_source": "registration",
  "label": "Primary Wallet",
  "created_at": "2026-05-19T12:00:00Z",
  "updated_at": "2026-05-19T12:00:00Z",
  "expires_at": "2026-06-18T12:00:00Z"
}
```

Balance semantics:

- `total_balance`: sum of validated coordinator-visible UTXOs,
- `reserved_balance`: sats reserved for open orders or active DLCs,
- `available_balance`: `total_balance - reserved_balance`.

The coordinator-visible balance is not necessarily the full wallet balance. It only reflects UTXOs the wallet has submitted and the coordinator has validated.

### How we did this in BullBitcoin

`DlcRepository.getWalletBalances()` calls `GET /auth/wallet/{wallet_id}` and returns the raw JSON. Balances are surfaced in `DlcState` as `totalBalanceSat`, `availableBalanceSat`, and `reservedBalanceSat`.

The primary balance refresh path is UTXO sync (Step 5), not a standalone wallet GET. If sync fails during `_reloadActiveWalletData()`, the cubit falls back to `getWalletBalances()` and shows a warning message.

## Step 5: Sync Wallet UTXOs

A registered wallet should keep the coordinator's UTXO set current.

```text
POST /auth/wallet/{wallet_id}/sync-utxos
Authorization: Bearer <wallet_token>
Content-Type: application/json
```

Request:

```json
{
  "nonce": "<nonce when UTXO signatures are required>",
  "utxos": [
    {
      "txid": "<txid>",
      "vout": 0,
      "signature": "<utxo ownership signature>",
      "public_key": "<hex public key>"
    }
  ]
}
```

Response extends the wallet response with sync details:

```json
{
  "wallet_id": "<wallet id>",
  "available_balance": 100000,
  "total_balance": 150000,
  "reserved_balance": 50000,
  "synced_utxo_count": 2,
  "rejected_utxos": [],
  "cancelled_orders": [],
  "preserved_locked_utxos": [],
  "utxo_sync_status": "ok",
  "warning": null
}
```

Recommended sync points:

- immediately after registration,
- when the wallet/account becomes active,
- before opening an order,
- before accepting a match,
- after order creation,
- after order cancellation,
- after accept submission,
- after maker signing and funding broadcast,
- after settlement or refund confirmation,
- after any external send or receive,
- before displaying balances if the local wallet state changed.

The coordinator may cancel open orders if their locked outpoints disappear or become spent. Live DLC funding inputs may be preserved in DLC state even if they are absent from a later sync, but they are not available balance.

After a successful **funding** or **CET/refund** broadcast, the coordinator also updates its coordinator-visible UTXO view (removes spent funding inputs, adds known change/payout outputs). The DLC funding output stays on the DLC record, not as spendable wallet balance. That projection is best-effort — wallets should still call `sync-utxos` to reconcile against the wallet’s own chain source.

### How we did this in BullBitcoin

`DlcRepository.syncActiveWalletUtxos()` implements client-driven sync:

1. `POST /auth/nonce`
2. Rebuild UTXO proofs from local wallet state (same algorithm as registration)
3. `POST /auth/wallet/{wallet_id}/sync-utxos` with `{ nonce, utxos }`
4. Parse into `DlcWalletSyncResult` (`totalBalanceSat`, `availableBalanceSat`, `reservedBalanceSat`, `warning`, `utxoSyncError`, `cancelledOrders`, `rejectedUtxos`)

**When sync runs:**

| Trigger | Location |
| --- | --- |
| Wallet activation / full reload | `DlcCubit._reloadActiveWalletData()` |
| Before order creation | `DlcRepository.createOrder()` (mandatory) |
| Before taker accept | `_trySyncActiveWalletUtxosForNegotiation()` |
| After order cancel, accept, sign, funding | best-effort `_trySyncActiveWalletUtxos()` |
| After coordinator funding/settlement broadcast (detected on poll) | `syncActiveWalletUtxosAfterCoordinatorProjection()` |
| Overview tab refresh | `DlcCubit.refreshOverviewTab()` |

`dlc_wallet_utxo_projection_utils.dart` compares previous and current order snapshots (`funding_txid` first seen, or `dlc_status` → `cet_broadcasted` / `refund_broadcasted`) and triggers sync from background polling and negotiation passes.

User messaging uses `formatDlcWalletSyncInfoMessage()` (`dlc_wallet_sync_utils.dart`) to explain cancelled open orders (e.g. spent UTXOs) while suppressing benign partial rejections. Overview **Balance split** notes that totals are coordinator-visible, not necessarily the full on-device wallet balance.

## Step 6: Optional Coordinator Refresh

The coordinator also exposes:

```text
POST /auth/wallet/{wallet_id}/refresh-balance
Authorization: Bearer <wallet_token>
```

This asks the coordinator to refresh tracked wallet UTXOs against its configured chain providers. Normal wallet integrations should prefer client-driven `sync-utxos`, because the wallet is the source of truth for which UTXOs it wants the coordinator to use.

Use refresh as a recovery or reconciliation tool, not as the primary UTXO discovery mechanism.

### How we did this in BullBitcoin

**Not implemented.** The app never calls `POST /auth/wallet/{wallet_id}/refresh-balance`. UTXO state is always wallet-driven via `syncActiveWalletUtxos()`, consistent with the guide's recommendation.

## Step 7: Discover Instruments

Fetch instruments before presenting trading choices:

```text
GET /instruments/non-expired
GET /instruments
GET /instruments/{instrument_id}
GET /instruments/id/{id}
```

Typical instrument fields:

```json
{
  "id": 123,
  "instrument_id": "BTC-18MAR26-74100-C",
  "type": "option",
  "oracle_label": "cassandra",
  "oracle_announcement_url": "https://...",
  "expires_at": "2026-03-18T00:00:00Z",
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-01-01T00:00:00Z"
}
```

Client requirements:

- show only non-expired instruments by default,
- do not hardcode instrument ids,
- parse option metadata from `instrument_id` if richer fields are unavailable,
- display underlying, expiry, strike, and right (`C` call or `P` put),
- display oracle label and maturity information,
- refresh instruments when the trading screen opens and periodically while open,
- prevent order submission for expired instruments unless operating in a deployment explicitly intended for demos.

### How we did this in BullBitcoin

`DlcRepository.listInstruments()` calls `GET /instruments/non-expired` in production (`ApiServiceConstants.dlcInstrumentsListPath`). When `DLC_SHOW_EXPIRED_INSTRUMENTS=true`, it uses `GET /instruments` instead.

Instruments are loaded on catalog init (`DlcCubit._loadCatalog()`) and filtered client-side by option type (call vs put) via `dlcInstrumentMatchesOptionType()`.

**Strike resolution:** Many coordinator instruments use a `STRIKE` placeholder in `instrument_id` (e.g. `BTC-18MAR26-STRIKE-C`). Before order creation, `_resolveCreateInstrumentId()` replaces `STRIKE` with the user-selected strike normalized by `dlcNormalizeStrikeToken()`. `_ensureLiveInstrumentId()` re-fetches the instrument list and rejects expired or unknown ids unless the dev flag is set.

Instrument metadata (underlying, expiry, right) is parsed from `instrument_id` strings in `dlc_instrument_utils.dart` for display on `DlcHomeScreen`.

## Step 8: Optional Payout Simulation

Before order creation, a wallet can ask the coordinator to simulate option economics from the wallet's perspective:

```text
POST /orders/option-payout-simulation
Authorization: Bearer <wallet_token>
X-Partner-Token: <partner_token>
Content-Type: application/json
```

Request:

```json
{
  "side": "buy",
  "role": "maker",
  "option_right": "C",
  "num_contracts": 1,
  "strike": 74100,
  "premium_per_contract_sats": 50000,
  "outcome_price": 80000,
  "premium_paid_upfront": false,
  "network_fee_sats": 0,
  "num_digits": 8
}
```

Use the response to render:

- estimated wallet PnL,
- wallet collateral,
- premium paid or received,
- estimated network fee,
- partner wallet fee,
- rounded settlement payout,
- canonical/theoretical payout,
- rounding delta,
- stepped rounded payout intervals,
- optional theoretical curve points.

The wallet should not reimplement coordinator payout rounding or partner fee math for authoritative values.

### How we did this in BullBitcoin

The Simulate tab builds a `DlcOptionPayoutSimulationRequest` from UI state (side, role, option right, contracts, strike, premium, outcome price) and calls `DlcRepository.simulateOptionPayout()` → `POST /orders/option-payout-simulation`.

The bearer token is included when a wallet is registered; the partner token is always present via the global interceptor. Results map to `DlcOptionPayoutSimulationResult` and drive the payout chart (`DlcOptionPayoutChart`).

For open/closed positions, `estimateWalletPnlSats()` (`dlc_wallet_pnl_utils.dart`) reuses the same endpoint with spot price or oracle outcome to estimate wallet PnL on the Overview tab — the app does not reimplement coordinator rounding.

## Step 9: Fetch Orderbook

Call:

```text
GET /orderbook/{instrument_id}
```

Typical response:

```json
{
  "instrument_id": "BTC-18MAR26-74100-C",
  "bids": [
    {
      "price": 123,
      "quantity": 1,
      "instrument_id": "BTC-18MAR26-74100-C",
      "strike": "74100"
    }
  ],
  "asks": []
}
```

Client requirements:

- label price and quantity units according to product requirements and OpenAPI,
- do not imply partial fills unless the coordinator schema explicitly supports them,
- treat the book as advisory context; final order matching happens when `POST /orders` is submitted.

### How we did this in BullBitcoin

`DlcRepository.getOrderbook(instrumentId)` → `GET /orderbook/{instrument_id}`.

The trading UI fetches orderbooks for a grid of suggested strikes: `DlcCubit._fetchStrikeOrderbooks()` resolves each strike into a concrete `instrument_id` (replacing `STRIKE`), then parallel-fetches books. Results are stored as `DlcStrikeOrderbookSnapshot` list in `DlcState.strikeOrderbooks`.

When the user taps a book level to trade, `createOrderMatchIntent` is set so the optimistic pending order shows match-oriented messaging. The coordinator still decides matching at `POST /orders` time; the app always sends `"price": null`.

Strike suggestions come from an external BTC-USD spot feed (`getBtcUsdSpotPrice()` → `DLC_BTC_USD_TICKER_URL`), rounded to $1,000 increments ±5 steps via `buildSuggestedStrikePrices()`.

## Step 10: Prepare Local DLC Funding Key

Before order creation, derive or select a DLC funding keypair controlled by the wallet.

The coordinator receives only:

```text
funding_pubkey_hex
```

The wallet must persist:

- the compressed public key hex,
- the local derivation path or key reference,
- the private-key lookup needed for later accept/sign work,
- the order id and DLC id once known,
- the funding input outpoint to key/address mapping when signing contexts are returned.

Do not derive a throwaway key that cannot be recovered after app restart. If the client loses the funding private key or derivation reference, it may be unable to finish the DLC protocol.

### How we did this in BullBitcoin

The DLC funding (interaction) key is deterministically derived from the wallet seed at a fixed BIP32 path:

```dart
String fundingDerivationPath(Wallet wallet) => '${wallet.derivationPath}/0/0';
```

`DlcLocalSigner.deriveFundingPubkey()` returns `DlcFundingPubkey { pubkeyHex, derivationPath }`. The public key hex is sent to the coordinator; the private key is re-derived on demand from `SeedRepository` during accept/sign — it is never persisted separately.

The derivation path and pubkey hex are stored on local order snapshots (`funding_pubkey_hex`, funding path metadata) in `DlcOrderStorage` so negotiation can resume after restart.

Per-UTXO keys for funding-input witness signatures use `{wallet.derivationPath}/{chain}/{index}` and are resolved at signing time via `resolveFundingInputSigningMaterials()` (`dlc_funding_key_resolve.dart`).

## Step 11: Create An Order

Call:

```text
POST /orders
Authorization: Bearer <wallet_token>
X-Partner-Token: <partner_token>
Content-Type: application/json
```

Request:

```json
{
  "instrument_id": "<instrument id>",
  "side": "buy",
  "quantity": 1,
  "price": null,
  "idempotency_key": "<stable client-generated key>",
  "funding_pubkey_hex": "<compressed secp256k1 public key hex>"
}
```

Field requirements:

- `instrument_id` must come from the instruments API,
- `side` is `buy` or `sell`,
- `quantity` is the option contract count,
- `price` is optional; pass `null` unless the product explicitly supports a price input for this deployment,
- `idempotency_key` should be generated before the first request and persisted,
- `funding_pubkey_hex` must be controlled by the active wallet.

Successful response:

```json
{
  "order_id": "<order id>",
  "dlc_id": "<dlc id>",
  "instrument_id": "<instrument id>",
  "side": "buy",
  "quantity": 1,
  "price": 50000,
  "status": "open",
  "created_at": "2026-05-19T12:00:00Z",
  "offer_object_hex": "<canonical OfferDLCMessage hex>",
  "accept_object_hex": null,
  "pending_match_accept": false,
  "matched_order_id": null,
  "matched_dlc_id": null,
  "matched_offer_object_hex": null
}
```

Persist at least:

- `order_id`,
- `dlc_id`,
- `instrument_id`,
- `side`,
- `quantity`,
- returned `price`,
- `status`,
- `offer_object_hex`,
- `idempotency_key`,
- `funding_pubkey_hex`,
- funding key derivation reference,
- active `wallet_id`,
- partner id,
- `created_at`.

Response handling:

- If `pending_match_accept == false`, the order is resting or otherwise not waiting for taker accept work.
- If `pending_match_accept == true`, this wallet is the taker for an immediate match and must continue to the accept flow.
- If the HTTP request times out, retry with the exact same body and same `idempotency_key`.
- If a duplicate/idempotency conflict is returned, fetch wallet orders and reconcile by `idempotency_key`.

The coordinator builds the canonical `OfferDLCMessage`. The wallet should store and display it for diagnostics if useful, but should not replace it.

### How we did this in BullBitcoin

**UI flow:** `DlcCubit.createOrder()` validates form state, inserts an optimistic local pending order (`local-pending-{timestamp}`), switches to the Orders tab, and completes creation in the background via `_completeCreateOrderInBackground()`.

**Repository flow:** `DlcRepository.createOrder(DlcOrderDraft)`:

1. Rejects expired wallet tokens and invalid quantity/price
2. **Mandatory** `syncActiveWalletUtxos()` before submit
3. Derives funding pubkey unless the draft already carries one
4. Resolves `instrument_id` (strike placeholder → concrete strike)
5. Builds idempotency fingerprint: `instrument|side|qty|strike|fundingPubkey`
6. `POST /orders` with `"price": null` always (UI premium is display-only)
7. Persists merged snapshot via `DlcOrderStorage` including `partner_id`, `idempotency_key`, `offer_object_hex`, match role
8. On 409 or transient failure, reconciles via `GET /orders` matching `idempotency_key`
9. Triggers `_runNegotiationWorker()` if `pending_match_accept`

**Idempotency:** `DlcIdempotencyStorage.getOrCreateCreateDraftKey()` generates a random 32-hex-char key per draft fingerprint, persisted in secure storage. Transient failures retry once with the same body; permanent failures clear the key unless 409/reconcile is possible.

**Error mapping in cubit:** 403 → partner token, 401 → wallet token expired, 404 → instrument not found, domain strings for insufficient balance and missing strike.

## Step 12: Interpret Order And DLC State

Read wallet-owned orders:

```text
GET /orders
GET /orders?instrument_id=<instrument_id>
GET /orders?status=open
GET /orders/{order_id}
```

Important order fields:

```json
{
  "order_id": "<order id>",
  "wallet_id": "<wallet id>",
  "partner_id": "<partner id>",
  "instrument_id": "<instrument id>",
  "side": "buy",
  "quantity": 1,
  "price": 50000,
  "status": "filled",
  "idempotency_key": "<key>",
  "matched_order_id": "<counterparty order id>",
  "match_role": "maker",
  "cancellation_reason": null,
  "dlc_id": "<dlc id>",
  "dlc_status": "accepted",
  "confirmation_status": null,
  "is_maker": true,
  "sign_required": true
}
```

Order statuses include:

- `open`: order is resting in the book,
- `pending_accept`: match is reserved but taker accept artifacts are not yet submitted,
- `filled`: order matched and entered the signed DLC lifecycle,
- `cancelled`: order was cancelled,
- `expired`: order expired,
- `rejected`: order failed validation or timed out during a match.

DLC statuses include:

- `offer_created`: offer exists, accept not yet complete,
- `accepted`: accept payload exists, maker sign still required,
- `signed`: sign payload exists and funding transaction has been built,
- `matured`: oracle event maturity reached,
- `attested`: oracle attestation available,
- `cet_broadcasted`: CET settlement broadcast,
- `cet_closed`: CET settlement confirmed,
- `refund_broadcasted`: refund broadcast,
- `refund_closed`: refund confirmed,
- `terminated`: terminal failed or manually terminated state.

`filled` is an order lifecycle state. It does not mean final economic settlement is complete. Final outcome is tracked on the DLC.

### How we did this in BullBitcoin

Orders are fetched via `DlcRepository.listOrders()` → `GET /orders` and mapped to `DlcOrderSummary` in `dlc_order_utils.dart`.

**Merge strategy:** `_mergeCoordinatorOrderJson()` prefers remote fields but preserves useful local-only data (`match_role`, `pending_match_accept`, strike, funding pubkey) when the list endpoint omits them.

**Enrichment:** `_enrichOrderWithDlcIfNeeded()` conditionally fetches `GET /dlcs/{dlc_id}` and `GET /dlcs/{dlc_id}/settlement-status`, governed by `dlc_dlc_detail_sync_utils.dart` (skip fetch when list data suffices; TTL cache 30 s live / 24 h closed).

**In-flight UI phases** (`DlcOrderInFlightPhase` in `dlc_order_in_flight.dart`):

| Phase | Meaning |
| --- | --- |
| `creatingOnCoordinator` | Optimistic local pending order |
| `matchedAwaitingTakerAccept` | Match detected, accept not started |
| `takerSigningAccept` | Accept context signing in progress |
| `makerSigningDlc` | Maker sign context signing in progress |

**Negotiation detection** (`dlc_negotiation_utils.dart`):

- `needsDlcTakerAccept()` — `status == pending_accept` or `pending_match_accept == true` (unless already `filled`)
- `needsDlcMakerSign()` — `sign_required == true`, maker role, DLC status `accepted` or `offer_created`
- `isDlcNegotiationComplete()` — `funding_txid` present or terminal DLC status

## Step 13: Run The Taker Accept Flow

The taker accept flow starts when a wallet creates an order and receives:

```json
{
  "pending_match_accept": true,
  "matched_order_id": "<maker order id>",
  "matched_dlc_id": "<maker dlc id>",
  "matched_offer_object_hex": "<maker offer hex>"
}
```

The wallet should immediately run or enqueue accept automation.

### 13.1 Sync UTXOs Before Accept

Call `POST /auth/wallet/{wallet_id}/sync-utxos` before accept if wallet UTXOs may have changed since order creation. The coordinator validates funding inputs, but fresh sync prevents avoidable stale-input failures.

### 13.2 Get Accept Context Counts

For progress estimates, call:

```text
POST /orders/{order_id}/accept-context-counts
Authorization: Bearer <wallet_token>
X-Partner-Token: <partner_token>
Content-Type: application/json
```

Request:

```json
{
  "funding_pubkey_hex": "<taker compressed funding pubkey>"
}
```

Response:

```json
{
  "order_id": "<taker order id>",
  "instrument_id": "<instrument id>",
  "cet_count": 37,
  "cet_signing_job_count": 886
}
```

This endpoint is optional, but useful for showing progress before downloading or signing a large context.

### 13.3 Get Accept Signing Context

```text
POST /orders/{order_id}/accept-context
Authorization: Bearer <wallet_token>
X-Partner-Token: <partner_token>
Content-Type: application/json
```

Request:

```json
{
  "funding_pubkey_hex": "<taker compressed funding pubkey>"
}
```

Response:

```json
{
  "order_id": "<taker order id>",
  "instrument_id": "<instrument id>",
  "offer_object_hex": "<canonical offer hex>",
  "context_fingerprint": "<fingerprint>",
  "cet_count": 37,
  "cet_signing_job_count": 886,
  "cet_signing_jobs": [
    {
      "message_hash_hex": "<32-byte hash hex>",
      "adaptor_point_hex": "<adaptor point hex>"
    }
  ],
  "refund_sighash_hex": "<refund sighash hex>",
  "funding_input_sighashes_hex": ["<funding input sighash hex>"],
  "funding_input_outpoints": ["<txid:vout>"],
  "funding_input_addresses": ["<address>"]
}
```

Client requirements:

- persist the exact context until accept completes,
- persist `context_fingerprint`,
- treat the context as immutable,
- validate that `offer_object_hex` matches the expected match,
- validate counts and array lengths,
- map each `funding_input_outpoints[]` entry to a local private key,
- map each funding input address to the expected local wallet ownership where possible,
- show progress if `cet_signing_job_count` is large.

### 13.4 Sign Accept Context Locally

The taker wallet must produce:

- one CET adaptor signature for each `cet_signing_jobs[]` item using the taker DLC funding private key,
- one refund signature for `refund_sighash_hex` using the taker DLC funding private key,
- one funding signature for each `funding_input_sighashes_hex[]` item using the private key controlling the matching UTXO.

Ordering is critical:

- `cet_adaptor_signatures_hex[i]` must correspond to `cet_signing_jobs[i]`,
- `funding_signatures_hex[i]` must correspond to `funding_input_sighashes_hex[i]`,
- do not sort or deduplicate arrays after signing.

The wallet should sign exactly the context it will submit. If the context is discarded or refreshed, discard the signatures too.

### 13.5 Submit Accept Artifacts

```text
POST /orders/{order_id}/accept-match
Authorization: Bearer <wallet_token>
X-Partner-Token: <partner_token>
Content-Type: application/json
```

Request:

```json
{
  "funding_pubkey_hex": "<same taker compressed funding pubkey>",
  "context_fingerprint": "<from accept-context>",
  "context_snapshot": {
    "optional": "original accept-context payload for diagnostics"
  },
  "idempotency_key": "accept:<order_id>:<context_fingerprint>",
  "cet_adaptor_signatures_hex": ["<adaptor signature hex>"],
  "refund_signature_hex": "<refund signature hex>",
  "funding_signatures_hex": ["<funding signature hex>"]
}
```

Successful response includes:

```json
{
  "order_id": "<taker order id>",
  "dlc_id": "<taker dlc id>",
  "status": "filled",
  "offer_object_hex": "<canonical offer hex>",
  "accept_object_hex": "<canonical AcceptDLCMessage hex>",
  "pending_match_accept": false,
  "matched_order_id": "<maker order id>",
  "matched_dlc_id": "<maker dlc id>",
  "matched_offer_object_hex": "<maker offer hex>"
}
```

On success, the coordinator:

- validates submitted signatures,
- assembles the canonical `AcceptDLCMessage`,
- persists accept payloads to both DLC rows,
- moves both DLCs to `accepted`,
- moves both orders to `filled`,
- keeps counterparty metadata on both orders,
- prepares the maker sign path.

### How we did this in BullBitcoin

Taker accept is fully automated in `DlcRepository._submitAcceptArtifacts()`, invoked from `runNegotiationPass()` when `needsDlcTakerAccept()` is true. It can also be driven manually via `progressOrderLifecycle()`.

**13.1 Pre-sync** — `_trySyncActiveWalletUtxosForNegotiation()` (best-effort).

**13.2 Accept context counts** — `POST /orders/{order_id}/accept-context-counts` is **not implemented**. Progress UI relies on `cet_signing_job_count` from the accept-context response.

**13.3 Accept context** — `POST /orders/{order_id}/accept-context` with `{ funding_pubkey_hex }`. Transient retry once on timeout/connection error.

**13.4 Local signing** — `DlcLocalSigner.signDlcContext(contextTag: 'accept', ...)` delegates heavy work to `runDlcContextSigningOffMainThread()` (Flutter `compute()` isolate in `dlc_context_signing_isolate.dart`). Produces:

- `cet_adaptor_signatures_hex` — 162-byte DLC wire format via `signCetAdaptorJobsFromCoordinatorContext()`
- `refund_signature_hex` — compact ECDSA over coordinator `refund_sighash_hex`
- `funding_signatures_hex` — P2WPKH witness stacks via `dlc_funding_signature_wire.dart`

**13.5 Submit** — `POST /orders/{order_id}/accept-match` with full `context_snapshot`, idempotency key, and signature arrays. Idempotency key from `DlcIdempotencyStorage.getOrCreateAcceptKeyForFingerprint()` keyed by `orderId:context_fingerprint`.

**Persistence before submit:** accept context fingerprint, snapshot, and `negotiation_status: accept_pending` are written to both `DlcOrderStorage` and `DlcNegotiationStorage`.

**Stale context:** on `context_mismatch` / `stale_context`, `rotateAcceptKey()` and retry once with a fresh context. Signatures from the old context are discarded.

**Reconciliation:** if accept is no longer required (`state_conflict`, benign messages), `_tryReconcileTakerAccept()` refreshes the order from `GET /orders/{order_id}`.

## Step 14: Run The Maker Sign Flow

The maker sign flow starts after a resting order has been matched and accepted by a taker.

The maker wallet detects this by polling:

```text
GET /orders
GET /orders/{order_id}
GET /dlcs/{dlc_id}
```

Run the maker sign flow when:

```text
order.status = filled
dlc.status = accepted
is_maker = true
sign_required = true
```

### 14.1 Get Sign Context

```text
GET /dlcs/{dlc_id}/sign-context
Authorization: Bearer <wallet_token>
```

Response:

```json
{
  "dlc_id": "<maker dlc id>",
  "order_id": "<maker order id>",
  "instrument_id": "<instrument id>",
  "offer_object_hex": "<canonical OfferDLCMessage hex>",
  "accept_object_hex": "<canonical AcceptDLCMessage hex>",
  "cet_count": 37,
  "cet_signing_job_count": 886,
  "cet_signing_jobs": [
    {
      "message_hash_hex": "<32-byte hash hex>",
      "adaptor_point_hex": "<adaptor point hex>"
    }
  ],
  "refund_sighash_hex": "<refund sighash hex>",
  "funding_input_sighashes_hex": ["<funding input sighash hex>"],
  "funding_input_outpoints": ["<txid:vout>"],
  "funding_input_addresses": ["<address>"]
}
```

Client requirements:

- persist the sign context until sign submission completes,
- validate that the context references the expected order and DLC,
- validate that `offer_object_hex` matches the stored offer,
- validate that `accept_object_hex` is present,
- map funding inputs to local keys,
- show progress for large CET signing jobs.

### 14.2 Sign The Sign Context Locally

The maker wallet must produce:

- one CET adaptor signature for each `cet_signing_jobs[]` item using the maker DLC funding private key,
- one refund signature for `refund_sighash_hex` using the maker DLC funding private key,
- one funding signature for each `funding_input_sighashes_hex[]` item using the private key controlling the matching maker UTXO.

Preserve array ordering exactly.

### 14.3 Submit Sign Artifacts

```text
POST /dlcs/{dlc_id}/sign
Authorization: Bearer <wallet_token>
X-Partner-Token: <partner_token>
Content-Type: application/json
```

Request:

```json
{
  "idempotency_key": "sign:<dlc_id>",
  "cet_adaptor_signatures_hex": ["<adaptor signature hex>"],
  "refund_signature_hex": "<refund signature hex>",
  "funding_signatures_hex": ["<funding signature hex>"]
}
```

Response:

```json
{
  "dlc_id": "<maker dlc id>",
  "status": "signed",
  "sign_object_hex": "<canonical SignDLCMessage hex>",
  "funding_tx_hex": "<funding tx hex>",
  "funding_txid": "<funding txid>",
  "funding_broadcasted": true,
  "funding_broadcast_error": null
}
```

On success, the coordinator:

- validates submitted maker signatures,
- assembles the canonical `SignDLCMessage`,
- persists sign payloads to both DLC rows,
- moves both DLCs to `signed`,
- builds the fully signed funding transaction,
- persists `funding_tx_hex`,
- attempts funding broadcast,
- persists `funding_txid` when broadcast succeeds.

Wallet-side negotiation automation is complete when the DLC reaches `signed`. After that, the wallet monitors funding, oracle, and settlement state.

### How we did this in BullBitcoin

Maker sign runs in `DlcRepository._submitMakerSignArtifacts()`, triggered when `needsDlcMakerSign()` is true.

**14.1 Sign context** — `GET /dlcs/{dlc_id}/sign-context` (no request body; maker funding pubkey was established at order creation).

**14.2 Local signing** — Same path as taker accept: `DlcLocalSigner.signDlcContext(contextTag: 'sign', ...)` in a background isolate. Array ordering is preserved exactly from context to submission.

**14.3 Submit** — `POST /dlcs/{dlc_id}/sign` with idempotency key from `DlcIdempotencyStorage.getOrCreateSignKeyForFingerprint()` keyed by `dlcId:context_fingerprint`.

On success:

- order/DLC snapshots updated with `sign_object_hex`, `funding_txid`, `funding_tx_hex`
- DLC detail cache invalidated
- UTXO sync if `funding_txid` is present

Stale-context handling mirrors accept: rotate sign idempotency key and retry once.

The app does not broadcast funding transactions locally — the coordinator builds, signs, and broadcasts after maker sign submission.

## Step 15: Monitor Funding

Read DLC funding transaction state:

```text
GET /dlcs/{dlc_id}/funding-transaction
Authorization: Bearer <wallet_token>
```

Response:

```json
{
  "dlc_id": "<dlc id>",
  "order_id": "<order id>",
  "status": "signed",
  "funding_tx_hex": "<funding tx hex>",
  "funding_txid": "<funding txid>",
  "funding_output_index": 0,
  "broadcasted": true,
  "last_error_reason": null,
  "last_error_message": null,
  "updated_at": "2026-05-19T12:00:00Z"
}
```

Client requirements:

- display funding txid when available,
- show pending broadcast if `funding_tx_hex` exists but `broadcasted == false`,
- display `last_error_reason` and `last_error_message` if broadcast failed,
- monitor transaction confirmation using the wallet's own chain source if desired,
- sync wallet UTXOs after funding broadcast so spent inputs are no longer shown as available for DLC use.

### How we did this in BullBitcoin

`GET /dlcs/{dlc_id}/funding-transaction` is defined in `DlcApiDatasource.getDlcFundingTransaction()` but **not called** from the repository or UI.

Funding state is inferred from fields on order/DLC list and detail responses:

- `funding_txid`, `funding_tx_hex`, `funding_broadcasted` (when present on sign response or DLC detail)
- DLC status progression to `signed` and beyond

When `funding_txid` appears after maker sign, `_trySyncActiveWalletUtxos()` runs so spent inputs leave the coordinator-visible balance. Order detail on `DlcHomeScreen` shows funding txid and broadcast status from merged `DlcOrderSummary` fields.

## Step 16: Monitor DLC Detail

Read DLC detail:

```text
GET /dlcs/{dlc_id}
Authorization: Bearer <wallet_token>
```

Important response fields:

```json
{
  "dlc_id": "<dlc id>",
  "order_id": "<order id>",
  "instrument_id": "<instrument id>",
  "offer_object_hex": "<offer hex>",
  "accept_object_hex": "<accept hex>",
  "sign_object_hex": "<sign hex>",
  "funding_txid": "<funding txid>",
  "funding_output_index": 0,
  "last_error_reason": null,
  "last_error_message": null,
  "oracle_outcome_value": null,
  "oracle_attested_at": null,
  "winning_cet_index": null,
  "settlement_type": null,
  "closing_txid": null,
  "refund_txid": null,
  "confirmed_at": null,
  "oracle_context": {},
  "status": "signed",
  "created_at": "2026-05-19T12:00:00Z",
  "updated_at": "2026-05-19T12:00:00Z"
}
```

Use this endpoint for detail screens, diagnostics, and state reconciliation.

### How we did this in BullBitcoin

`DlcApiDatasource.getDlc()` → `GET /dlcs/{dlc_id}` enriches orders via `_enrichOrderWithDlcIfNeeded()`.

**Fetch optimization** (`dlc_dlc_detail_sync_utils.dart`):

- Skip `GET /dlcs/{id}` when the order list already carries sufficient DLC fields for the current UI state
- In-memory TTL cache in `DlcRepository._dlcDetailCacheByKey`: 30 seconds for live DLCs, 24 hours for closed/settled

**Merged fields** into `DlcOrderSummary`: `dlcStatus`, `settlementType`, `fundingTxid`, `closingTxid`, `refundTxid`, `oracleOutcomeValue`, collateral, network fees, partner fees.

404 on order or DLC detail triggers `_purgeLocalCoordinatorSnapshot()` — local order, negotiation state, and idempotency keys are removed to prevent infinite retry loops.

## Step 17: Monitor Oracle And Settlement Status

After funding, settlement is driven by oracle maturity, oracle attestation, and coordinator settlement logic.

Read settlement status:

```text
GET /dlcs/{dlc_id}/settlement-status
Authorization: Bearer <wallet_token>
```

Response:

```json
{
  "dlc_id": "<dlc id>",
  "order_id": "<order id>",
  "status": "attested",
  "settlement_type": "cet",
  "oracle_outcome_value": "80000",
  "oracle_attested_at": "2026-05-19T12:00:00Z",
  "winning_cet_index": 12,
  "closing_txid": "<settlement txid>",
  "refund_txid": null,
  "confirmed_at": null,
  "last_error_reason": null,
  "last_error_message": null,
  "oracle_context": {},
  "updated_at": "2026-05-19T12:00:00Z"
}
```

Read oracle attestation:

```text
GET /dlcs/{dlc_id}/attestation
Authorization: Bearer <wallet_token>
```

Response:

```json
{
  "dlc_id": "<dlc id>",
  "order_id": "<order id>",
  "status": "attested",
  "oracle_attestation_hex": "<attestation hex>",
  "oracle_outcome_value": "80000",
  "oracle_attested_at": "2026-05-19T12:00:00Z",
  "last_error_reason": null,
  "last_error_message": null,
  "oracle_context": {},
  "updated_at": "2026-05-19T12:00:00Z"
}
```

Client requirements:

- display oracle maturity and attestation status,
- display outcome value when available,
- display whether settlement is expected to use a CET or refund path,
- display closing or refund txid when available,
- display confirmation status when available,
- sync wallet UTXOs after settlement, refund, or change outputs become spendable.

### How we did this in BullBitcoin

Settlement visibility uses two coordinator endpoints:

1. `GET /dlcs/{dlc_id}/settlement-status` — primary settlement snapshot (`status`, `settlement_type`, oracle outcome, closing/refund txids)
2. `GET /dlcs/{dlc_id}` — supplementary detail (fees, confirmation timestamps, oracle context)

These are merged in `_mergeSettlementAndDetail()` / `_mergeDlcDetailIntoOrder()`.

**Not wired:** `GET /dlcs/{dlc_id}/attestation` and `GET /dlcs/{dlc_id}/payout-data` exist in `DlcApiDatasource` but are not called. Oracle attestation hex is not displayed separately; outcome value and settlement type come from settlement-status and DLC detail.

The background poll (`_backgroundPollTick` every 15 seconds) refreshes orders for signed-or-later DLCs. Closed positions show settlement txids and oracle outcome on the order detail sheet in `DlcHomeScreen`.

Wallet PnL for closed positions uses `estimateWalletPnlSats()` with the oracle outcome as `outcome_price` in the payout simulation endpoint.

## Step 18: Read DLC Events

For an activity feed or diagnostics:

```text
GET /dlcs/{dlc_id}/events
Authorization: Bearer <wallet_token>
```

Response:

```json
[
  {
    "event_id": "<event id>",
    "dlc_id": "<dlc id>",
    "event_type": "accept_signing_context_generated",
    "payload": {},
    "created_at": "2026-05-19T12:00:00Z"
  }
]
```

Events are useful for support views, audit trails, and showing the user what happened when a flow is slow or failed.

### How we did this in BullBitcoin

**Not implemented.** `GET /dlcs/{dlc_id}/events` is not called. Slow-flow feedback relies on in-flight order phases, negotiation status fields in local storage, and coordinator error messages surfaced through `DlcCubit` state (`errorMessage`, `infoMessage`).

## Step 19: Cancel Open Orders

Only open orders can be cancelled by the wallet:

```text
POST /orders/{order_id}/cancel
Authorization: Bearer <wallet_token>
```

Response is an `OrderDetailResponse`.

Client requirements:

- only enable cancellation for `status == "open"`,
- after successful cancellation, sync UTXOs,
- display `cancellation_reason` if present,
- handle `400` if the order is no longer open because it matched or expired.

### How we did this in BullBitcoin

`DlcCubit.cancelOpenOrder(orderId)` → `DlcRepository.cancelOrder()` → `POST /orders/{order_id}/cancel`.

Only orders with `status == open` show a cancel action in the UI. After success, the repository refreshes the order list and runs `_trySyncActiveWalletUtxos()` so reserved balance is updated. `cancellation_reason` from the coordinator is displayed on the order detail sheet when present.

## Step 20: Polling Worker

Each wallet should run a small idempotent negotiation worker while the DLC feature is active.

Recommended loop:

```text
on app start or wallet activation:
  check readiness
  check partner config
  refresh active wallet registration if needed
  sync wallet UTXOs
  list wallet orders

on order creation response:
  persist response
  if pending_match_accept:
    run taker accept flow

every 2 to 5 seconds while trading UI is open:
  list wallet orders
  for pending_accept orders where match_role == taker:
    run or resume taker accept flow
  for filled orders where is_maker and sign_required:
    run or resume maker sign flow
  for signed or later DLCs:
    refresh funding and settlement status

on external wallet balance change:
  sync wallet UTXOs

on app restart:
  reload local order/DLC state
  list wallet orders
  resume unfinished accept/sign work from persisted state
```

A production client can use websocket or push notifications if available, but should still keep polling as a fallback.

### How we did this in BullBitcoin

The negotiation worker is implemented in `DlcCubit`:

| Mechanism | Implementation |
| --- | --- |
| On app start / wallet activation | `_reloadActiveWalletData()` → readiness, auth validation, UTXO sync, order list |
| On order creation | `_completeCreateOrderInBackground()` → `_runNegotiationWorker()` if accept/negotiation needed |
| Background poll | `Timer.periodic(15 s)` via `_configureBackgroundPolling()` → `_backgroundPollTick()` |
| Poll triggers | `_backgroundPollTick()` refreshes orders and calls `_runNegotiationWorker(showProcessing: false)` when `hasOrdersNeedingNegotiation()` |
| Wallet switch guard | `_walletSessionGeneration` counter prevents stale async updates after switching wallets |

`DlcRepository.runNegotiationPass()` scans active-wallet orders, resolves negotiation targets, and sequentially runs taker accept (`_submitAcceptArtifacts`) and maker sign (`_submitMakerSignArtifacts`). Benign errors (`isBenignDlcNegotiationMessage()`) are suppressed in background mode.

Manual progression: `fulfillOrder()` / `progressOrderLifecycle()` loops up to 6–8 steps for user-initiated retry of stuck orders.

There is no websocket integration; polling is the sole automation mechanism.

## Local State To Persist

For each registered wallet:

- coordinator base URL,
- network,
- partner id,
- `wallet_id`,
- `wallet_token`,
- `expires_at`,
- xpub reference,
- local wallet/account reference,
- last successful UTXO sync time,
- last coordinator-visible balance.

For each order:

- `order_id`,
- `dlc_id`,
- `instrument_id`,
- `side`,
- `quantity`,
- `price`,
- `status`,
- `idempotency_key`,
- `offer_object_hex`,
- `accept_object_hex` if known,
- `sign_object_hex` if known,
- `matched_order_id`,
- `matched_dlc_id`,
- `match_role`,
- `is_maker`,
- `sign_required`,
- `cancellation_reason`,
- active `wallet_id`,
- partner id.

For each active DLC signing flow:

- DLC funding public key,
- DLC funding key derivation reference,
- local funding private-key lookup reference,
- funding input outpoint to address/key mapping,
- latest accept context fingerprint,
- exact accept context payload until accept completes,
- accept idempotency key,
- latest sign context payload until sign completes,
- sign idempotency key,
- operation status such as `accept_context_fetched`, `accept_submitted`, `sign_context_fetched`, `sign_submitted`, `funding_broadcasted`.

This state makes the integration restart-safe. The client should be able to resume after a process crash, app update, device sleep, or transient network failure without reusing stale signatures against a new context.

### How we did this in BullBitcoin

All coordinator integration state is stored in platform secure storage via `KeyValueStorageDatasource<String>`, partitioned by mainnet/testnet:

| Storage class | Secure key | Contents |
| --- | --- | --- |
| `DlcAuthStorage` | `dlc_wallet_auth_mainnet` / `_testnet` | `wallet_id`, `wallet_token`, `expires_at`, xpub, active wallet origin id; supports multiple registered wallets |
| `DlcOrderStorage` | `dlc_order_snapshots_*` | Coordinator order JSON merged with local fields (strike, funding pubkey/path, negotiation status, context snapshots) |
| `DlcNegotiationStorage` | `dlc_negotiation_state_*` | Per-order funding pubkey, accept context fingerprint, negotiation status |
| `DlcIdempotencyStorage` | `dlc_idempotency_keys_*` | Create keys by draft fingerprint; accept keys by `orderId:fingerprint`; sign keys by `dlcId:fingerprint` |

Coordinator base URL and network are not stored per-wallet — they follow app environment settings and `.env`. Partner token is never stored in secure storage; it remains in application config only.

On 404 from the coordinator, `_purgeLocalCoordinatorSnapshot()` removes the order snapshot plus all related negotiation and idempotency keys for that order/DLC.

## Idempotency Rules

Use stable idempotency keys for mutating protocol steps:

```text
order:<wallet_id>:<client_order_uuid>
accept:<order_id>:<context_fingerprint>
sign:<dlc_id>
```

Rules:

- generate the key before the first request,
- persist it before sending the request,
- retry timeouts with the same body and same key,
- do not change payload fields under the same key,
- if a context fingerprint changes, generate a new accept idempotency key,
- reconcile ambiguous outcomes by listing orders or reading the DLC.

### How we did this in BullBitcoin

`DlcIdempotencyStorage` persists keys in secure storage before the HTTP request is sent:

| Step | Key scheme | Storage |
| --- | --- | --- |
| Create order | Random 32-hex UUID per draft fingerprint (`instrument\|side\|qty\|strike\|fundingPubkey`) | `createByDraft` map |
| Accept match | `accept-{random}` per `orderId:context_fingerprint` | `acceptByOrder` map |
| Maker sign | `sign-{random}` per `dlcId:context_fingerprint` | `signByDlc` map |

Keys are generated with `Random.secure()` via `_newKey(prefix)`.

**Retry behavior:**

- Create: single transient retry with same body; 409 → reconcile via `GET /orders`; clear key on permanent failure
- Accept/sign: single transient retry; context mismatch → `rotateAcceptKey()` / `rotateSignKey()` then re-fetch context and re-sign
- Successful accept/sign → clear the idempotency key for that fingerprint

The guide's canonical string formats (`order:<wallet_id>:<uuid>`, etc.) are illustrative; BullBitcoin uses opaque random tokens keyed by draft/order/DLC fingerprint in local storage rather than embedding wallet ids in the key string.

## Stale Context Handling

If the coordinator returns a stale-context or context-mismatch error during accept/sign submission:

1. discard the local context, 2. discard signatures derived from that context, 3. fetch a new context, 4. revalidate the new context, 5. re-sign the new context, 6. submit with a new idempotency key if the fingerprint changed.

Never reuse signatures from one context against another context.

### How we did this in BullBitcoin

Both `_submitAcceptArtifacts()` and `_submitMakerSignArtifacts()` run a two-attempt loop:

1. Fetch context → sign → submit
2. On `_isContextMismatch(e)` (coordinator returns stale-context or context-mismatch errors), rotate the idempotency key, **discard signatures**, fetch a fresh context, re-sign, and submit again

Local context snapshots in `DlcOrderStorage` are overwritten on each fetch. Signatures are never persisted to disk — they exist only in memory for the duration of the submit attempt.

## Signature Artifact Requirements

Accept and sign submissions contain signature artifacts, not private keys.

The client sends:

- compressed DLC funding public keys,
- CET adaptor signatures,
- refund signatures,
- funding input signatures,
- optional context snapshots for diagnostics.

The client never sends:

- seed phrases,
- xprivs,
- raw private keys,
- wallet passwords,
- local signing secrets,
- private nonce material.

The exact serialization of adaptor signatures and funding signatures must match the live OpenAPI schema and DLC implementation used by the deployment.

### How we did this in BullBitcoin

All signing is centralized in `DlcLocalSigner` + `dlc_context_signing_isolate.dart`:

| Artifact | Implementation |
| --- | --- |
| CET adaptor signatures | `signCetAdaptorJobsFromCoordinatorContext()` in `dlc_cet_adaptor_signing.dart`; 162-byte DLC wire format using `EcdsaAdaptor` from core DLC crypto |
| Refund signature | Compact secp256k1 over coordinator-provided `refund_sighash_hex` |
| Funding input signatures | P2WPKH witness stack serialization in `dlc_funding_signature_wire.dart` |
| Registration/xpub proofs | DER-encoded ECDSA via `dlc_ecdsa_der.dart` (`compactSecp256k1SignatureToDerHex`) |
| UTXO ownership proofs | DER signatures over `SHA256(txid + vout + nonce)` |

Private keys are loaded from `SeedRepository.get(wallet.masterFingerprint)` inside the signer or isolate. No private material is logged or transmitted.

Heavy CET adaptor signing runs off the UI thread via Flutter `compute()` to keep `DlcHomeScreen` responsive during large `cet_signing_job_count` values.

## Validation The Wallet Should Perform

Before signing any context, the wallet should validate as much as practical:

- the context belongs to the expected order and DLC,
- the context belongs to the active registered wallet,
- `offer_object_hex` matches the stored offer for the flow,
- `accept_object_hex` is present for maker sign,
- `context_fingerprint` is present for accept,
- CET job count matches `cet_signing_jobs.length`,
- funding sighash count matches funding outpoint count,
- funding outpoints belong to wallet-controlled UTXOs,
- funding input addresses match local wallet expectations where possible,
- expiry and oracle context match the selected instrument,
- array order is preserved from context to submission.

Some deep validation, such as fully independently validating every DLC message, CET, and adaptor point, may be implemented in phases. The wallet should still structure the integration so those checks can be added without changing the API flow.

### How we did this in BullBitcoin

Validation is pragmatic rather than exhaustive:

- **Pre-trade:** wallet token expiry, positive quantity, non-negative premium, live instrument check, mandatory UTXO sync
- **Pre-sign:** funding input keys resolved via outpoint/address hints in `resolveFundingInputSigningMaterials()`; missing keys throw before submit
- **Post-fetch:** array lengths from accept/sign context are consumed as-is; CET job ordering preserved index-by-index
- **Post-submit:** 404 purges stale local state; accept-no-longer-required paths reconcile from coordinator order GET

Full independent verification of `offer_object_hex` / adaptor points against the DLC spec is not implemented yet. The integration boundary (repository + signer) is structured so additional validators can be inserted before `signDlcContext()` without changing API call sequences.

## Error Handling

Typical HTTP status handling:

| Status | Meaning | Client action |
| --- | --- | --- |
| `400` | Invalid payload, insufficient balance, invalid state, validation failure. | Show actionable error; refresh wallet/order state. |
| `401` | Invalid nonce or expired wallet token. | Re-register or refresh wallet auth. |
| `403` | Wrong wallet, missing partner token, invalid partner token, or access denied. | Disable protected action and check configuration. |
| `404` | Missing wallet, order, DLC, or instrument. | Refresh local state and instrument list. |
| `409` | Duplicate/conflicting creation or stale context. | Reconcile by idempotency key or refetch context. |
| `500` | Coordinator-side failure. | Retry if safe; show temporary service error. |

Important domain errors to handle:

- insufficient available balance,
- instrument expired,
- partner token expired or mismatched,
- wallet token expired,
- pending accept timed out,
- self-match blocked,
- stale accept context,
- context mismatch,
- invalid adaptor signatures,
- invalid refund signature,
- invalid funding signatures,
- funding broadcast failure,
- settlement failure.

### How we did this in BullBitcoin

HTTP errors are parsed in `DlcApiDatasource._readApiError()` from FastAPI-style `detail` fields (string, object with `reason`/`message`, or validation list) into `DlcApiException` with `statusCode`, `message`, `isTimeout`, and `isConnectionError` flags.

| Scenario | BullBitcoin handling |
| --- | --- |
| 401/403 on wallet GET | Clear auth storage; show expired wallet banner |
| 403 on create | Partner token configuration error in UI |
| 404 on order/DLC | Purge local snapshot; stop retrying |
| 409 on create | Reconcile via order list + idempotency key |
| Timeout / connection | Single retry on create, accept-context, accept-match; backup URL for reads |
| Context mismatch | Rotate idempotency key; re-fetch and re-sign |
| Accept no longer required | `_tryReconcileTakerAccept()`; suppress in background worker |
| Transient negotiation failure | `isBenignDlcNegotiationMessage()` filters noise in background mode |

Domain-level helpers live in `dlc_negotiation_utils.dart` and `dlc_order_utils.dart` (`isCoordinatorResourceNotFound`, `isAcceptSigningNoLongerRequired`, etc.).

## Security Checklist

Before production launch, verify:

- private keys never leave the wallet boundary,
- partner token is not logged or exposed to users,
- wallet token is stored securely,
- idempotency keys are stable and persisted,
- contexts and signatures are not logged in unsafe locations,
- funding key derivation references survive app restart,
- order/DLC records are scoped by wallet id and partner id,
- network mismatch disables trading,
- stale contexts cannot be signed or submitted,
- all coordinator responses are treated as untrusted input until validated,
- failure messages avoid leaking secrets.

### How we did this in BullBitcoin

| Checklist item | Implementation |
| --- | --- |
| Private keys stay local | `SeedRepository` + `DlcLocalSigner`; only signatures submitted |
| Partner token not logged/exposed | `.env` only; never in secure storage or UI fields |
| Wallet token stored securely | `DlcAuthStorage` via platform secure storage |
| Idempotency keys persisted | `DlcIdempotencyStorage` in secure storage |
| Contexts/signatures not logged unsafely | Signatures not persisted; debug prints gated |
| Funding key survives restart | Deterministic BIP32 path `{derivationPath}/0/0` |
| Orders scoped by wallet | Snapshots keyed by `walletOriginId` + environment |
| Network mismatch warning | `_buildCoordinatorTradingHint()` compares app env vs coordinator readiness |
| Stale contexts not reused | Two-attempt loop with key rotation |
| Untrusted coordinator input | Parsed defensively; 404 triggers local purge |

## User Experience Checklist

A wallet client should expose:

- coordinator availability,
- active registered wallet,
- token expiration or re-registration state,
- coordinator-visible available balance,
- instruments and expiry,
- orderbook context,
- payout simulation,
- order creation progress,
- resting order state,
- taker accept progress,
- maker sign required state,
- funding transaction broadcast status,
- oracle maturity and attestation status,
- settlement or refund transaction status,
- clear cancellation and failure reasons.

Avoid presenting `filled` as final settlement. Explain through UI state that a filled order has entered a DLC lifecycle and final settlement depends on funding, oracle attestation, and settlement confirmation.

### How we did this in BullBitcoin

`DlcHomeScreen` exposes the checklist items through tabs and state-driven UI:

| UX element | Source |
| --- | --- |
| Coordinator availability | `coordinatorTradingHint` banner |
| Registered wallet + balances | Overview tab; `totalBalanceSat` / `availableBalanceSat` / `reservedBalanceSat` |
| Expired registration | `expiredWallets` list + re-register action |
| Instruments + strikes | Trade tab; strike grid with live orderbooks |
| Payout simulation | Simulate tab + `DlcOptionPayoutChart` |
| Order creation progress | Optimistic pending order + `creatingOnCoordinator` phase |
| Accept/sign progress | `takerSigningAccept` / `makerSigningDlc` in-flight phases |
| Order detail | Sheet with DLC status, funding/settlement txids, fees, oracle outcome |
| Cancellation | Cancel button on open orders only |
| `filled` ≠ settled | Closed vs live order styling; settlement txids shown separately from match status |

Wallet PnL on the Overview tab aggregates open and closed positions via payout simulation.

## Minimal Happy Path Endpoint List

For a complete wallet integration, expect to implement at least:

```text
GET  /auth/system-readiness
GET  /partners/{partner_id}/config
POST /auth/nonce
GET  /auth/nonce/{nonce}
POST /auth/wallet
GET  /auth/wallet/{wallet_id}
POST /auth/wallet/{wallet_id}/sync-utxos
GET  /instruments/non-expired
GET  /orderbook/{instrument_id}
POST /orders/option-payout-simulation
POST /orders
GET  /orders
GET  /orders/{order_id}
POST /orders/{order_id}/cancel
POST /orders/{order_id}/accept-context-counts
POST /orders/{order_id}/accept-context
POST /orders/{order_id}/accept-match
GET  /dlcs/{dlc_id}
GET  /dlcs/{dlc_id}/sign-context
POST /dlcs/{dlc_id}/sign
GET  /dlcs/{dlc_id}/funding-transaction
GET  /dlcs/{dlc_id}/payout-data
GET  /dlcs/{dlc_id}/settlement-status
GET  /dlcs/{dlc_id}/attestation
GET  /dlcs/{dlc_id}/events
```

Some products can launch with a smaller subset, but any production wallet that creates and accepts DLC option orders should support the full order, accept, sign, funding, settlement, cancellation, and UTXO sync lifecycle.

### How we did this in BullBitcoin — endpoint coverage

| Endpoint | Status in BullBitcoin mobile |
| --- | --- |
| `GET /auth/system-readiness` | **Used** — catalog load, trading hint |
| `GET /partners/{partner_id}/config` | **Not used** — partner token from env |
| `POST /auth/nonce` | **Used** — registration and UTXO sync |
| `GET /auth/nonce/{nonce}` | **Not used** |
| `POST /auth/wallet` | **Used** — registration |
| `GET /auth/wallet/{wallet_id}` | **Used** — balance fallback, token validation |
| `POST /auth/wallet/{wallet_id}/sync-utxos` | **Used** — primary balance/UTXO path |
| `POST /auth/wallet/{wallet_id}/refresh-balance` | **Not used** |
| `GET /instruments/non-expired` | **Used** — instrument catalog |
| `GET /orderbook/{instrument_id}` | **Used** — per-strike orderbooks |
| `POST /orders/option-payout-simulation` | **Used** — Simulate tab + wallet PnL |
| `POST /orders` | **Used** — order creation |
| `GET /orders` / `GET /orders/{order_id}` | **Used** — order list, reconciliation, detail |
| `POST /orders/{order_id}/cancel` | **Used** |
| `POST /orders/{order_id}/accept-context-counts` | **Not used** |
| `POST /orders/{order_id}/accept-context` | **Used** — taker accept |
| `POST /orders/{order_id}/accept-match` | **Used** — taker accept submit |
| `GET /dlcs/{dlc_id}` | **Used** — detail enrichment (cached) |
| `GET /dlcs/{dlc_id}/sign-context` | **Used** — maker sign |
| `POST /dlcs/{dlc_id}/sign` | **Used** — maker sign submit |
| `GET /dlcs/{dlc_id}/funding-transaction` | **Defined, not wired** |
| `GET /dlcs/{dlc_id}/payout-data` | **Defined, not wired** |
| `GET /dlcs/{dlc_id}/settlement-status` | **Used** — settlement polling |
| `GET /dlcs/{dlc_id}/attestation` | **Defined, not wired** |
| `GET /dlcs/{dlc_id}/events` | **Not implemented** |

All HTTP calls are centralized in `lib/features/dlc/data/dlc_api_datasource.dart`. Integration logic lives in `lib/features/dlc/data/dlc_repository.dart`.
