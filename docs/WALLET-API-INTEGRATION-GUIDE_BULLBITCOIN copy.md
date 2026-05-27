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

- nonce creation,
- wallet registration,
- partner configuration,
- order creation,
- accept context and accept submission,
- maker sign submission,
- option payout simulation.

Some read endpoints only require the wallet bearer token. Use the live OpenAPI schema for the exact header set of the deployed coordinator.

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

Client requirements:

- verify the coordinator is reachable,
- verify the environment matches the wallet network,
- disable trading if critical blockers are present,
- show degraded status if `chain_backend.ok` is false,
- use environment-specific messaging for test deployments.

For `testnet3`, `testnet4`, `signet`, and `mainnet`, the coordinator API performs chain lookup, UTXO validation, raw previous transaction lookup, fee/broadcast provider calls, and settlement confirmation checks through bitcoinlib providers such as ElectrumX. Wallet clients do not need the coordinator to have Bitcoin Core RPC credentials on these networks. Public-network deployments must configure `.bitcoinlib/providers.json` with a reachable provider for the active network.

For `regtest`, `chain_backend` still represents the ElectrumX/bitcoinlib path used by runtime API flows. `regtest_mining` is reported separately and is only needed for coordinator-managed local demo funding/bootstrap endpoints such as `POST /auth/admin/wallet/regtest-funded`.

The readiness response does not replace wallet-side network checks. A wallet must still ensure that its own keys, UTXOs, addresses, and transactions belong to the same Bitcoin network as the coordinator.

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

## Step 3: Register A Wallet

Wallet registration gives the coordinator a wallet identity, initial UTXO set, and wallet bearer token. Registration is also the first UTXO sync.

### 3.1 Request A Nonce

```text
POST /auth/nonce
X-Partner-Token: <partner_token>
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

Use the nonce to bind wallet ownership proofs to a short-lived challenge. Nonce creation is partner-protected: clients must send the assigned partner access token in `X-Partner-Token`. The client does not send `partner_id` in the nonce or wallet registration body; the coordinator resolves the partner from the token.

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
- `xpub_signature`: a DER-encoded hex signature proving control of the submitted `xpub` using the nonce,
- `label`: a wallet display label,
- `utxos`: the current wallet-selected UTXOs that the coordinator may consider,
- one UTXO ownership signature per submitted UTXO when validation is enabled.

#### XPUB Signature Format

The coordinator verifies `xpub_signature` by recreating a temporary bitcoinlib wallet from the submitted `xpub`, taking that wallet's public master key, and verifying a DER signature over the nonce. This is not Bitcoin Core `signmessage`.

The message to sign is the nonce string returned by `POST /auth/nonce`, encoded exactly as:

```python
message_hex = nonce.encode("utf-8").hex()
```

Then sign `message_hex` with the private extended key corresponding to the submitted public extended key. Send the signature as DER-encoded hex. When using `bitcoinlib.keys.sign()`, pass `message_hex` directly; bitcoinlib internally normalizes non-32-byte messages by double-SHA256 hashing before producing the ECDSA signature. The coordinator mirrors that normalization during verification.

Do not sign JSON. Do not sign the xpub. Do not add the Bitcoin Signed Message prefix. Do not base64-encode the signature. Do not pre-transform the nonce differently from `nonce.encode("utf-8").hex()` before handing it to the signing primitive.

The signing algorithm does not change between regtest, testnet, and mainnet. What changes is the key prefix and the network that the coordinator will use for UTXO validation:

| Network | Typical public extended keys | Typical private extended keys |
| --- | --- | --- |
| Mainnet | `xpub`, `ypub`, `zpub` | `xprv`, `yprv`, `zprv` |
| Testnet / regtest | `tpub`, `upub`, `vpub` | `tprv`, `uprv`, `vprv` |

The submitted `xpub` and the private extended key used for signing must be a matching pair for the same wallet/account scope. If the coordinator runs with `BITCOIN_NETWORK=testnet3`, submitted UTXOs must be testnet3 UTXOs. If it runs with `BITCOIN_NETWORK=bitcoin`, submitted UTXOs must be mainnet UTXOs. A valid xpub signature can still be rejected later if UTXOs belong to the wrong network or are not found by the coordinator's chain backend.

Reference implementation:

```python
import requests
from bitcoinlib.keys import HDKey, sign as bitcoinlib_sign

API_BASE = "https://coordinator.example.com"
PARTNER_TOKEN = "prt__..."

# Private extended key corresponding to WALLET_XPUB. Keep it local.
# Mainnet examples: xprv/yprv/zprv with xpub/ypub/zpub.
# Testnet/regtest examples: tprv/uprv/vprv with tpub/upub/vpub.
XPUB_SIGNING_PRIVATE_KEY = "..."
WALLET_XPUB = "..."

headers = {
    "X-Partner-Token": PARTNER_TOKEN,
    "Content-Type": "application/json",
}

nonce_response = requests.post(
    f"{API_BASE}/auth/nonce",
    headers=headers,
    json={},
    timeout=30,
)
nonce_response.raise_for_status()
nonce = nonce_response.json()["nonce"]

signing_key = HDKey(import_key=XPUB_SIGNING_PRIVATE_KEY)
message_hex = nonce.encode("utf-8").hex()
xpub_signature = bitcoinlib_sign(message_hex, signing_key).as_der_encoded().hex()
```

Backend-equivalent verification:

```python
from bitcoinlib.keys import verify
from bitcoinlib.wallets import Wallet, wallet_delete
import uuid

def double_sha256(data: bytes) -> bytes:
    import hashlib
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()

def backend_verify_xpub_signature(nonce: str, xpub_signature_hex: str, xpub: str) -> bool:
    message_hex = nonce.encode("utf-8").hex()
    message_bytes = bytes.fromhex(message_hex)
    if len(message_bytes) != 32:
        message_hex = double_sha256(message_bytes).hex()

    temp_wallet_name = f"verify_temp_{uuid.uuid4().hex[:8]}"
    try:
        verifying_wallet = Wallet.create(temp_wallet_name, xpub)
        verifying_key = verifying_wallet.public_master().key()
        return verify(message_hex, xpub_signature_hex, verifying_key)
    finally:
        wallet_delete(temp_wallet_name, force=True)
```

Common xpub-signature rejection causes:

- the client signed a different nonce,
- the client signed the xpub or request JSON instead of the nonce,
- the client used Bitcoin Core `signmessage`,
- the client sent base64 or compact signature bytes instead of DER hex,
- the submitted public extended key does not match the private extended key used to sign,
- the client signed with a single address private key rather than the extended private key corresponding to the submitted `xpub`,
- the nonce was encoded differently from `nonce.encode("utf-8").hex()`.

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
  "xpub_signature": "<DER signature hex over nonce UTF-8 hex>",
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

## Step 6: Optional Coordinator Refresh

The coordinator also exposes:

```text
POST /auth/wallet/{wallet_id}/refresh-balance
Authorization: Bearer <wallet_token>
```

This asks the coordinator to refresh tracked wallet UTXOs against its configured chain providers. Normal wallet integrations should prefer client-driven `sync-utxos`, because the wallet is the source of truth for which UTXOs it wants the coordinator to use.

Use refresh as a recovery or reconciliation tool, not as the primary UTXO discovery mechanism.

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
- persists `funding_txid` when broadcast succeeds,
- projects known wallet UTXO changes after successful broadcast.

Funding broadcast projection removes the maker and taker funding inputs from the coordinator-visible wallet UTXO sets and adds wallet-owned funding transaction change outputs when the coordinator can map the output script to the corresponding wallet. The DLC funding output is tracked on the DLC record and is not added as normal wallet balance.

Wallet-side negotiation automation is complete when the DLC reaches `signed`. After that, the wallet monitors funding, oracle, and settlement state.

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
- sync wallet UTXOs after funding broadcast if the wallet wants to reconcile the coordinator's projected UTXO set against its own chain source.

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
- sync wallet UTXOs after settlement or refund if the wallet wants to reconcile coordinator-projected payout outputs against its own chain source.

After a successful CET or refund broadcast, the coordinator projects wallet-owned payout outputs into the corresponding wallet UTXO sets when ownership is known from the DLC payout scripts. Projection is best-effort and does not replace client-driven `sync-utxos`.

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

## Stale Context Handling

If the coordinator returns a stale-context or context-mismatch error during accept/sign submission:

1. discard the local context, 2. discard signatures derived from that context, 3. fetch a new context, 4. revalidate the new context, 5. re-sign the new context, 6. submit with a new idempotency key if the fingerprint changed.

Never reuse signatures from one context against another context.

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
