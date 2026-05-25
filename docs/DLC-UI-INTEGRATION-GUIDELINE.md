# DLC UI Integration Guideline (BullBitcoin Mobile)

This document describes how the Bull Bitcoin mobile wallet implements the DLC trading UI that connects to the DLC Coordinator API. It is written for an AI agent or engineer implementing a **similar client in another Flutter app**.

The agnostic API contract lives in [WALLET-API-INTEGRATION-GUIDE_BULLBITCOIN.md](./WALLET-API-INTEGRATION-GUIDE_BULLBITCOIN.md). This guide covers **presentation only**: layout, content, interactions, state, and UX patterns.

---

## 1. Architectural overview

### 1.1 Single route, four tabs

The DLC feature is one screen with four tabs — not four separate routes.

| Item | Value |
| --- | --- |
| Route | `/dlcs` (`DlcRouter` in `lib/features/dlc/ui/dlc_router.dart`) |
| Screen widget | `DlcHomeScreen` |
| State | `DlcCubit` + `DlcState` (flutter_bloc) |
| DI | `BlocProvider` creates cubit from GetIt at route entry |

On first frame, `DlcCubit.load()` runs. That loads **catalog data only** (instruments, wallets, readiness). **Wallet session** (registration, balances, orders) starts only after the user taps **Activate** on Overview.

### 1.2 File map

| Concern | Location |
| --- | --- |
| Main UI | `lib/features/dlc/ui/screens/dlc_home_screen.dart` (~3,250 lines; tab panels are private widgets in the same file) |
| Payout chart | `lib/features/dlc/ui/widgets/dlc_option_payout_chart.dart` |
| Blocking overlay | `lib/features/dlc/ui/widgets/dlc_action_loading_overlay.dart` |
| In-flight order UX | `lib/features/dlc/domain/dlc_order_in_flight.dart` |
| Order list bucketing | `lib/features/dlc/domain/dlc_order_utils.dart` |

**Implementer note:** For a greenfield app, split `dlc_home_screen.dart` into one file per tab. BullBitcoin keeps everything in one file for iteration speed; the logical boundaries below are the split points.

### 1.3 Layering rule

```
UI (DlcHomeScreen)
  → reads/writes DlcState
  → calls DlcCubit methods
    → DlcRepository (API + signing + persistence)
      → DlcApiDatasource (HTTP)
      → DlcLocalSigner (keys/signatures)
```

The UI **never** calls HTTP or signing directly, except the Simulate tab which calls `DlcRepository.simulateOptionPayout()` via the service locator for convenience. Prefer routing that through the cubit in a new app.

---

## 2. Shared shell (all four tabs)

Every tab shares the same scaffold. Implement this once; tab bodies swap inside the scroll area.

### 2.1 Top navigation — pill tab bar

**Widget:** `_DlcHomeTopNav`

| Tab index | Label | Icon | Purpose |
| --- | --- | --- | --- |
| 0 | Overview | `dashboard_outlined` | Wallet activation, balances, summary stats |
| 1 | Trade | `menu_book_outlined` | Orderbook + create order form |
| 2 | My Orders | `list_alt_outlined` | Open / live / closed order lists |
| 3 | Simulate | `calculate_outlined` | Hypothetical payout calculator |

**Design:**

- Rounded container (`borderRadius: 18`) on `surfaceContainerLow` with subtle outline.
- Each tab: icon (23px) + label (13px, w700 when selected).
- Selected tab: elevated `surface` chip with outline; primary-colored icon.
- Disabled while `state.loading || _simulateLoading` (opacity 0.42).

**Interactions:**

- `onSelect(index)` → `DlcCubit.setTab(index)`.
- Switching to **Trade** (index 1) triggers `refreshOrderbookTab()` (re-fetches strike orderbooks).
- Tab bar does **not** auto-refresh other tabs on select; user pull-to-refreshes instead.

### 2.2 ColdPay attribution

**Widget:** `_DlcColdPayAttribution`

Small right-aligned “Powered by ColdPay.” link (Bitcoin-orange period). Opens `https://www.coldpay.me` externally. Pure branding — no API coupling. Omit or replace in another wallet’s build.

### 2.3 Transient message banners

Two dismissible banners above tab content (not a SnackBar — stays until dismissed or cleared):

| State field | Style | When set |
| --- | --- | --- |
| `errorMessage` | `errorContainer` / `onErrorContainer`, error icon | API failures, validation errors |
| `infoMessage` | `primaryContainer` / `onPrimaryContainer`, info icon | Success hints, UTXO sync notes, order placed |

Dismiss → `DlcCubit.clearTransientMessages()`.

**UX rule:** Use banners for session-level outcomes the user should notice after navigation (e.g. “order placed, check My Orders”). Use SnackBars only for inline field validation (Simulate tab).

### 2.4 Pull-to-refresh

`RefreshIndicator` wraps the tab `ListView`. Calls `DlcCubit.refreshCurrentTab()` which dispatches:

| Tab | Method | API touchpoints |
| --- | --- | --- |
| Overview | `refreshOverviewTab()` | UTXO sync, order list, wallet PnL |
| Trade | `refreshOrderbookTab()` | Instruments, strikes, per-strike orderbooks |
| My Orders | `refreshOrdersTab()` | `GET /orders`, negotiation worker kick |
| Simulate | no-op | — |

### 2.5 Blocking loading overlay

**Widget:** `DlcActionLoadingOverlay`

Full-screen semi-transparent scrim + centered brand sync GIF. Visible when:

```dart
state.actionInProgress || state.orderbookRefreshing || _simulateLoading
```

| Flag | Typical cause |
| --- | --- |
| `actionInProgress` | Wallet activate/register, create order start (not background completion) |
| `orderbookRefreshing` | Strike orderbook batch fetch |
| `_simulateLoading` | Simulate tab POST in flight |

**UX rule:** Block input during **user-initiated mutations** and **orderbook reload**, not during background negotiation (accept/sign). Background work shows hourglass icons on order rows instead.

### 2.6 Theme and visual language

Follow Material 3 `ColorScheme` — do not hardcode a full palette except where trading semantics need it:

| Semantic | Color | Usage |
| --- | --- | --- |
| Buy / bid | `#1B5E20` (dark green) | Side labels, bid column, positive PnL (light mode) |
| Sell / ask | `#B71C1C` (dark red) | Side labels, ask column |
| Positive PnL (dark mode) | `#81C784` | Simulate + Overview PnL |
| Cards | `Card` + 12–16px padding | All major sections |
| Section headers | Icon (18px, primary) + `titleMedium` w600 | Consistent across tabs |

Adapt colors to the host wallet theme, but **keep buy=green / sell=red** — users expect this on trading surfaces.

---

## 3. Screen 0 — Overview

**Widget:** `_OverviewPanel`  
**Purpose:** Onboard the wallet to DLC, show coordinator-visible balances, high-level portfolio stats, and risk copy. This is the **gate** before trading.

### 3.1 Coordinator trading hint (conditional)

**When:** `state.coordinatorTradingHint != null`

**Content:** Multi-line warning assembled in `DlcCubit._buildCoordinatorTradingHint()` from:

- Missing partner token
- Readiness fetch failure
- Unhealthy bitcoin node / ElectrumX
- Non-empty readiness `blockers`
- Network mismatch (regtest vs mainnet, testnet vs mainnet)

**Design:** Card with error-colored border, warning icon, `bodySmall` text.

**API:** `GET /auth/system-readiness` (loaded at catalog init; not re-fetched on every Overview refresh unless full reload).

**Implementer Q: Should this block trading?**  
Partially. `_tradingBlocked()` disables **Create** on Trade when hint mentions environment mismatch. Other issues show warning but allow browsing; create may still fail with 403/401.

### 3.2 Wallet activation card

Two modes based on `state.auth == null`.

#### Mode A — Not activated (`auth == null`)

| Element | Content / behavior |
| --- | --- |
| Title | “Activate wallet” + wallet icon |
| Body | Explains that balances, orders, and UTXO sync run **after** Activate |
| Dropdown | “Bitcoin wallet for DLC” — lists `state.availableWallets` with suffix `(registered)` / `(not registered)` |
| Button | **Activate** → `DlcCubit.activateWalletForDlc(selectedWalletOriginId)` |

**API on Activate (new wallet):**

1. `POST /auth/nonce`
2. Local nonce + UTXO proofs
3. `POST /auth/wallet`
4. Store token in secure storage

**API on Activate (already registered):**

1. Switch active wallet in local storage only
2. `GET /auth/wallet/{id}` validation
3. Background: balances, UTXO sync, orders

**Overlay during activate:** `actionInProgress = true` → blocking overlay.

#### Mode B — Activated (`auth != null`)

| Element | Content / behavior |
| --- | --- |
| Title | “Wallet registered” + verified icon |
| Tappable area | Wallet label + “Tap to view details or switch active wallet” |
| Tap | Opens **Registered wallet** dialog |

**Registered wallet dialog:**

- Shows label, token expiry (if known)
- Dropdown to pick another on-chain Bitcoin wallet
- **Activate** switches/registers selected wallet

**Implementer Q: Why separate catalog load vs activation?**  
Users can browse instruments and simulate payouts before registering. Registration exposes UTXOs to the coordinator — it should be an explicit consent step.

### 3.3 Summary stat cards row

**Widget:** `_OverviewSummaryCardsRow` — two square `AspectRatio(1)` cards side by side.

#### Card A — Wallet PnL

| State | Display |
| --- | --- |
| No auth | `—` |
| Auth + PnL computed | `+1,234,567 sats` (green/red by sign) |

**API / logic:** `estimateWalletPnlSats()` aggregates `POST /orders/option-payout-simulation` across open and closed positions (not a single coordinator endpoint). Computed during `_reloadActiveWalletData()` / `refreshOverviewTab()`.

#### Card B — Order counts

Label: **Open / Live / Closed**  
Value: `2 / 1 / 5` or `— / — / —` if not registered.

Uses same bucketing rules as My Orders tab (`orderShowsInOpenSection`, `orderShowsInLiveSection`, `isDlcClosedOrder`).

### 3.4 Balance split card

**Widget:** `_BarStatCard` — title “Balance split”

| Element | Source |
| --- | --- |
| Subtitle | Explains coordinator-visible balances; suggests UTXO sync after funding/settlement |
| Progress bar | Ratio `available / total` |
| Labels | `Available: {availableBalanceSat}` · `Reserved: {reservedBalanceSat}` |

**API:** Primary path `POST /auth/wallet/{id}/sync-utxos` during wallet hydration. Fallback `GET /auth/wallet/{id}` if sync fails.

**Implementer Q: Why show coordinator balance, not full wallet balance?**  
The coordinator only reserves UTXOs the client submitted. Trading limits follow **coordinator-visible available**, not the user’s total on-chain balance.

### 3.5 Risk disclosure card

Static copy: DLC options lock collateral; only xpubs and signatures leave the device; seeds stay local. No API call. Required for regulatory/UX trust on a self-custody wallet.

### 3.6 Recent DLC events (placeholder)

Section title “Recent DLC events” with copy: “No dedicated events endpoint exposed by coordinator API yet.”

**Future:** When `GET /dlcs/{id}/events` is wired, replace with a chronological feed of last N events across active DLCs.

### 3.7 Expired registrations (conditional)

**When:** `state.expiredWallets.isNotEmpty`

Lists archived `wallet_id` + xpub for wallets whose bearer token failed validation. User must re-register from activation flow.

---

## 4. Screen 1 — Trade

**Layout:** Two stacked cards inside the tab scroll view:

1. **Orderbook** (`_OrderbookInstrumentCard`)
2. **Create order** (inline `Card` in `DlcHomeScreen.build`)

Trade requires `state.auth != null` for create; orderbook browsing works without auth.

### 4.1 Orderbook card

#### Instrument selector (tappable header)

Shows selected instrument template id (e.g. `BTC-18MAR26-STRIKE-C`), underlying, CALL/PUT, expiry UTC. Tap opens instrument picker overlay (`_openPickerOverlay`) to choose expiry series and option type (call/put).

**API:** Instruments from `GET /instruments/non-expired` (already in `state.instruments`). Changing instrument → `DlcCubit.selectOptionInstrumentAndStrike()` → refreshes strike suggestions and orderbooks.

#### Strike summary table

**Widget:** `_StrikeOrderbookSummaryTable`

| Column | Content |
| --- | --- |
| Strike | USD formatted (`$74,100`) — tappable |
| Ask | Lowest ask premium (sats per contract), red |
| Bid | Highest bid premium (sats per contract), green |

One row per strike in `state.strikeOrderbooks`. Data from parallel `GET /orderbook/{instrument_id}` calls (instrument id resolved per strike by replacing `STRIKE` in template).

**Empty states:**

- Loading + empty snapshots → `CircularProgressIndicator`
- Loaded + empty → “No liquidity on any strike yet.”
- No instrument → “Select an instrument to view strikes.”

**Helper text:** “Tap a strike to view full depth. Premiums are per contract (sats).”

#### Strike detail dialog (modal)

Tap a strike row → `_showStrikeOrderbookDetailDialog`:

| Section | Content |
| --- | --- |
| Title | Resolved instrument id for that strike |
| Maturity | Expiry timestamp |
| Asks table | Up to 10 rows: premium × quantity |
| Bids table | Same |

**Row tap behavior:** Closes dialog and calls `_applyDepthRowToCreateOrder()`:

- Sets strike, side (buy on ask tap, sell on bid tap), quantity, premium from row
- Updates text controllers
- Sets `createOrderMatchIntent = true` (optimistic match UX)

**Own orders on book:** Rows matching user’s open orders show **dashed underline**. Info button explains this. Detection: `dlcOrderbookRowIsOwnWalletOpenOrder()`.

**Info dialogs:**

- Ask/bid header (i) → premium is per full contract (1 BTC = 1 contract)
- Own orders (i) → dashed underline meaning

**API:** Same orderbook endpoint; no separate “my orders on book” API — client matches locally against `state.orders`.

### 4.2 Create order card

#### Header

“Create order” + info button → dialog explaining:

- Matching is **exact quantity only** (no partial fills)
- “Filled” is market state, not final settlement

#### Side selector

`SegmentedButton<DlcOrderSide>`: **Buy** | **Sell**  
→ `DlcCubit.setSide()`

#### Strike field

**Widget:** `_CreateOrderStrikeField`

- Dropdown of strikes (same list as orderbook table)
- Required when instrument uses `STRIKE` template
- Refresh button (tonal icon) → `refreshStrikePrices()` → external BTC-USD ticker + `$1,000` step suggestions
- Error from `state.strikePriceError`

**API note:** UI premium and strike are **local**. Coordinator receives `price: null`; matching uses orderbook liquidity, not the premium field.

#### Quantity field

- Label: “Number of contracts”
- Helper: “1 contract = 1 BTC. Minimum 0.01 contracts.”
- Controller synced with cubit on change (`setQuantity`)
- Default: `0.01`

#### Premium field

- Label: “Premium per contract (option price)”
- Helper: “Satoshis per contract (whole number).”
- Default from env `DLC_DEFAULT_PREMIUM_SATOSHIS_PER_CONTRACT`
- Display-only for coordinator create (still useful for user intent and match-intent trimming)

#### Estimated total

Read-only: `price × quantity` formatted as grouped satoshis.

#### Create button

`ElevatedButton.icon` **Create** — enabled when:

- `state.auth != null`
- `!_tradingBlocked(state)` (no env mismatch in hint)

→ `DlcCubit.createOrder()`

**Create order UX sequence (critical):**

1. **Optimistic:** Insert local order `local-pending-{timestamp}` with phase `creatingOnCoordinator`
2. **Navigate:** Switch to tab index 2 (My Orders)
3. **Info banner:** “opened” vs “placed and matched” depending on `createOrderMatchIntent`
4. **Background:** `_completeCreateOrderInBackground()` → `POST /orders` (+ sync, negotiation worker)
5. **No blocking overlay** for background completion — hourglass on order row instead

If match intent, optimistically trim touched orderbook level locally (`optimisticTrimOrderbookForMatch`).

**API:** `POST /orders` with `instrument_id` (strike-resolved), `side`, `quantity`, `price: null`, `idempotency_key`, `funding_pubkey_hex`.

---

## 5. Screen 2 — My Orders

**Layout:** Three stacked `_OrderGroupSection` cards.

### 5.1 Section bucketing

| Section | Subtitle | Orders included | Cancel? |
| --- | --- | --- | --- |
| **Open orders** | Waiting for a match | `orderShowsInOpenSection` — includes optimistic `creatingOnCoordinator` | Yes |
| **Live orders** | Pending accept, filled, settlement in progress | `orderShowsInLiveSection` — accept/sign/wait states | No |
| **Closed / settled** | Completed DLCs | `isDlcClosedOrder` | No |

Empty section → single ListTile “No orders in this section”.

**Implementer Q: Why is “creating” under Open, not Live?**  
User mental model: until coordinator confirms match, the order is “on the book” or being placed — same section as resting orders.

### 5.2 Order row — `_CompactOrderEntry`

Each row is a bordered mini-card:

| Column | Content |
| --- | --- |
| Primary | `instrument_id` (ellipsis) |
| Secondary | Side (color) · Created timestamp |
| Actions | Hourglass and/or info; optional cancel |

#### In-flight hourglass

**When:** `order.inFlightPhase != null` (local) or derived via `resolveOrderInFlightPhase()`

| Phase | Icon color | Info button? | Dialog title |
| --- | --- | --- | --- |
| `creatingOnCoordinator` | primary | No | Opening order |
| `takerSigningAccept` | primary | Yes | Signing acceptance |
| `matchedAwaitingTakerAccept` | primary | Yes | Match in progress |
| `makerSigningDlc` | tertiary | Yes | Maker signing |

Tap hourglass → `_showOrderInFlightDialog` with phase-specific body copy (background work, user can keep using app).

**API mapping:** Phases derive from order fields (`pending_match_accept`, `sign_required`, `dlc_status`) — no separate polling UI. Background `runNegotiationPass()` every 15s drives accept/sign.

#### Order info dialog

Tap (i) → `_showOrderInfoDialog`:

| Field | Source |
| --- | --- |
| Instrument | `order.instrumentId` |
| Seller collateral (sats) | Parsed from order/DLC enrichment |
| Contracts | `order.quantity` |
| Premium in contract (sats) | Order utils |
| Side / Role | `formatDlcOrderRole` (maker/taker) |
| Order status | Coordinator `status` |
| DLC status | Enriched `dlcStatus` |
| Partner / network fees | Enriched from DLC detail when available |
| Order ID | Selectable text |
| Created | Localized datetime |

**API:** Mostly from `GET /orders` list; fees/settlement from conditional `GET /dlcs/{id}` enrichment.

#### Cancel flow

Only in **Open orders** section when `showCancel: true`.

1. Confirm dialog explains coordinator cancel + orderbook removal
2. `DlcCubit.cancelOpenOrder(orderId)` → `POST /orders/{id}/cancel`
3. Refresh list + balances + UTXO sync info banner

Disabled while `state.processingOrder`.

### 5.3 Background automation (invisible UI)

Not a visible element, but explains order row updates:

- `Timer.periodic(15s)` when any order needs negotiation or status poll
- `runNegotiationPass()` → accept-context → sign → accept-match / sign
- User sees hourglass → then status jumps to Live/Closed without explicit “Sign now” button

**Implementer Q: Should we add explicit “Sign” buttons?**  
Optional power-user affordance. BullBitcoin automates by default because signing hundreds of CET adaptors takes seconds–minutes and must survive app backgrounding. If you add a button, still run the same worker as fallback.

---

## 6. Screen 3 — Simulate

**Widget:** `_SimulateTabPanel` (private `StatefulWidget` in `dlc_home_screen.dart`)  
**State class:** `_SimulateTabPanelState`  
**Purpose:** Educational/hypothetical payout calculator. **No wallet auth required, no orders, no signing, no funds at risk.** Use it to help users understand option settlement before they trade.

The screen is structured as three vertically stacked Material 3 `Card`s:

1. **Input card** (always visible) — “Simulate payout”
2. **Payout chart card** (only when `_result != null`) — title `Payout for [LONG|SHORT] [PUT|CALL]`
3. **Simulation results card** (only when `_result != null`) — numeric breakdown of the response

The tab keeps its **own** form/result state inside `_SimulateTabPanelState`. It deliberately does **not** mutate `DlcState`, so the user can experiment freely without overwriting the Trade tab’s in-progress create form.

### 6.1 Lifecycle, state, and locator usage

```dart
class _SimulateTabPanelState extends State<_SimulateTabPanel> {
  late final TextEditingController _contractsController;
  late final TextEditingController _strikeController;
  late final TextEditingController _premiumController;
  late final TextEditingController _expiryBtcUsdController;
  late final TextEditingController _networkFeeController;

  DlcOrderSide _role = DlcOrderSide.buy;      // buyer | seller
  DlcOptionType _optionKind = DlcOptionType.call; // PUT | CALL
  String _orderRole = 'maker';                // maker | taker (coordinator role)

  bool _loading = false;                      // request in flight
  String? _error;                             // inline error banner inside card
  DlcOptionPayoutSimulationResult? _result;   // last successful response

  int _chartStrikeUsd = 0;                    // captured at SIMULATE press
  int _chartOutcomeUsd = 0;                   // captured at SIMULATE press
  final _payoutChartKey = GlobalKey();        // for auto-scroll
}
```

Notes:

- **Captured chart inputs.** `_chartStrikeUsd` / `_chartOutcomeUsd` are written **only** at the moment the SIMULATE button succeeds. The chart axes, vertical guides, legend values, and title therefore always match the **simulated** scenario, even if the user keeps typing in the strike or outcome fields afterwards.
- **Parent loading.** The state widget receives a callback `onLoadingChanged(bool)` from `DlcHomeScreen`. The parent mirrors that boolean into its own `_simulateLoading` field, which feeds the **shared blocking overlay** (`DlcActionLoadingOverlay`) used by the rest of the DLC screen.
- **Repository call.** The tab calls `locator<DlcRepository>().simulateOptionPayout(req)` directly. In a greenfield app, route this through the cubit for consistency.

### 6.2 Defaulting rules (initial field values)

`initState()`:

| Field | Default | Rule |
| --- | --- | --- |
| Contracts | `1` | Literal |
| Strike (USD) | `state.btcUsdSpotPrice?.round() ?? 70000` | Spot price already cached in `DlcState`, else hard fallback `_kSimulateStrikeFallbackUsd = 70000` |
| Premium (sats) | `state.price.round()` | Same default as the Trade tab’s premium |
| Expiry BTC/USD | `state.btcUsdSpotPrice?.round()` or blank | Spot price if known, else empty hint |
| Network fee (sats) | `0` | Literal |
| Side | `DlcOrderSide.buy` (= `LONG`) | Literal |
| Option kind | `DlcOptionType.call` | Literal |
| Order role | `'maker'` | Literal |

#### Spot fallback hydration

If `state.btcUsdSpotPrice == null` at panel creation:

1. The strike field is pre-filled with `70000` (fallback constant).
2. `_refreshSimulateStrikeFromSpotIfNeeded()` runs asynchronously and calls `locator<DlcRepository>().getBtcUsdSpotPrice()` (BTC/USD ticker URL from app config).
3. If the ticker returns and **the strike field still contains exactly the `"70000"` fallback** (i.e. the user has not edited it), it is replaced with the live spot price.
4. If the ticker call fails, the field stays at `70000`. Silent — no error UI for this background refresh.

`didUpdateWidget` repeats the same “replace only if still `70000`” logic whenever the parent pushes a new `DlcState` that newly contains `btcUsdSpotPrice`. This means: the moment the cubit hydrates spot from any other tab’s refresh, an untouched Simulate strike field is upgraded from `70000` to live spot.

This guarantees:

- The user never sees an empty strike field.
- A user who manually typed any other strike is never overridden.

### 6.3 Input card — “Simulate payout”

Section header (no `Spacer` between widgets — info icon is right-aligned with a `Spacer`):

> **Icon:** `Icons.calculate_outlined` (size 18, primary)  
> **Title:** “Simulate payout” (`titleMedium`, `FontWeight.w600`)  
> **Trailing:** `IconButton(Icons.info_outline, tooltip: "About simulate payout")` → opens the **About** dialog (see §6.7).

The body uses **inline sentence + segmented controls / fields**, not a vertical form. Each sentence is a `Wrap` so it reflows on narrow phones:

#### Sentence 1 — role, quantity, option type

> “I am the **[buyer|seller]** of **[qty]** contracts of **[PUT|CALL]** Bitcoin option.”

Implemented as a `Wrap` with `spacing: 6, runSpacing: 12`. Pieces, in order:

1. `Text('I am the')`
2. `SegmentedButton<DlcOrderSide>` with two segments: `buyer` (`DlcOrderSide.buy`) and `seller` (`DlcOrderSide.sell`). Compact style, no selected icon, min height 34.
3. `Text('of')`
4. `_contractsField()` — width 88, decimal `TextField`, hint `qty`.
5. `Text('contracts of')`
6. `SegmentedButton<DlcOptionType>` with segments `PUT` and `CALL`. **Note:** segments are ordered `PUT` first, `CALL` second.
7. `Text('Bitcoin option.')`

#### Sentence 2 — order role

> “My order role: **[Maker|Taker]**”

Single `SegmentedButton<String>` with values `'maker'` and `'taker'`. Sent to the API as `role`.

#### Sentence 3 — strike & premium

> “The strike price is set at **[strike] USD** and the premium per contract is **[premium] sats**.”

- `_usdField` for strike: width 112, integer/decimal `TextField`, `suffixText: 'USD'`, hint `strike`.
- `_premiumField()` for premium: width 130, digits-only `TextField`, `suffixText: 'sats'`, hint `premium`.

#### Sentence 4 — outcome BTC/USD

> “Check my profit or loss if the Bitcoin price at expiry is **[BTC/USD]**.”

`_usdField` width 120, digits-only (`allowDecimal: false`), hint `BTC/USD`, `suffixText: 'USD'`.

#### Network fee block

A small subtitle `'Estimated network fee you pay (on-chain)'` (`bodySmall`, `onSurfaceVariant`) followed by a `TextField` (width 200, digits-only, `labelText: 'Network fees'`, `suffixText: 'sats'`).

#### Inline error region

When `_error != null`, a `Container` with `errorContainer` background renders the message in `onErrorContainer` text. This is an **inline** error inside the input card — separate from the shared red banner above the tabs.

#### SIMULATE button

Full-width `ElevatedButton.icon` with `Icons.play_arrow_outlined` and label `'SIMULATE'`. Enabled iff `!_loading` (deliberately **no** wallet-auth gate — simulating without an activated wallet is the most common entry point).

### 6.4 Submit pipeline — `_runSimulation()`

1. **Dismiss keyboard:** `FocusScope.of(context).unfocus()`.
2. **Validate inputs (SnackBars, not banners):**

   | Check | SnackBar text |
   | --- | --- |
   | `qty <= 0` or NaN | `Enter a valid number of contracts (> 0).` |
   | `strike < 1` or NaN | `Strike must be at least 1 (whole BTC/USD units).` |
   | `premium < 0` or NaN | `Premium per contract must be a whole sats amount ≥ 0.` |
   | `outcome < 0` or NaN | `Expiry BTC/USD must be a whole number ≥ 0.` |
   | `networkFee < 0` | `Network fee estimate cannot be negative.` |

   Each validation failure returns early before any API call.

3. **Enter loading state:** `_loading = true`, `_error = null`, `widget.onLoadingChanged(true)` (parent renders the blocking overlay).
4. **Build request:**

   ```dart
   DlcOptionPayoutSimulationRequest(
     side: _role == DlcOrderSide.buy ? 'buy' : 'sell',
     role: _orderRole,                                  // 'maker' | 'taker'
     optionRight: _optionKind == DlcOptionType.call ? 'C' : 'P',
     numContracts: qty,
     strike: strikeInt,                                 // rounded int
     premiumPerContractSats: premium,
     outcomePrice: outcome,                             // int
     premiumPaidUpfront: true,                          // fixed
     networkFeeSats: networkFee,
     numDigits: 8,                                      // fixed
   );
   ```

5. **Call repository:** `locator<DlcRepository>().simulateOptionPayout(req)`. The repository attaches the wallet bearer token **only if a wallet is registered**; otherwise it calls `POST /orders/option-payout-simulation` unauthenticated.

6. **Success path:**
   - `_result = result; _chartStrikeUsd = strikeInt; _chartOutcomeUsd = outcome;`
   - `_loading = false`, `widget.onLoadingChanged(false)`.
   - `_scrollToPayoutChart()` — `WidgetsBinding.addPostFrameCallback` → `Scrollable.ensureVisible(_payoutChartKey.currentContext!, alignment: 0.08, duration: 350ms, curve: Curves.easeOutCubic)`. Brings the chart card close to the top of the viewport but with a small margin, so the user immediately sees the chart and can swipe down for metrics.

7. **Failure path:**
   - `DlcApiException`: store `e.message` in both `_error` (inline banner) **and** show it via SnackBar.
   - Any other exception: same pattern with `e.toString()`.
   - `_result = null` is set in both error branches so the chart and metrics cards disappear.

#### Why no auth gate?

`DlcRepository.simulateOptionPayout` does **not** require a `DlcWalletAuth`. It will send the bearer token if available, but the coordinator endpoint works anonymously. The SIMULATE button is enabled even before activation so users can test scenarios on first visit.

### 6.5 Payout chart card

When `_result != null`, the second card renders.

**Title** (no strike or outcome in the title text):

```dart
String _simulatePayoutCurveTitle({
  required DlcOrderSide role,
  required DlcOptionType optionKind,
}) {
  final direction = role == DlcOrderSide.buy ? 'LONG' : 'SHORT';
  final right = optionKind == DlcOptionType.call ? 'CALL' : 'PUT';
  return 'Payout for $direction $right';     // e.g. "Payout for LONG CALL"
}
```

| Side selector | Title fragment |
| --- | --- |
| buyer | `LONG` |
| seller | `SHORT` |

| Option kind | Title fragment |
| --- | --- |
| CALL | `CALL` |
| PUT | `PUT` |

Header icon: `Icons.show_chart_outlined` (size 18, primary). The `Text` is wrapped in `Expanded` so the title ellipses safely on narrow screens.

#### Widget: `DlcOptionPayoutChart`

File: `lib/features/dlc/ui/widgets/dlc_option_payout_chart.dart`

```dart
DlcOptionPayoutChart(
  result: _result!,
  strikeUsd: _chartStrikeUsd,
  outcomeUsd: _chartOutcomeUsd,
);
```

Layout: a `Column` with two parts.

1. A 228 px tall `CustomPaint` wrapped in `SizedBox(height: 228, width: double.infinity)`, painting the chart.
2. An 8 px gap, then a small `Wrap` legend (`spacing: 10, runSpacing: 6`).

#### Legend chips (compact, `labelSmall`)

```dart
_LegendChip(color: scheme.primary,                 label: 'Actual payout'),
_LegendChip(color: scheme.onSurfaceVariant…,       label: 'Canonical payout',           dashed: true),
_LegendChip(color: scheme.tertiary,                label: 'Strike (<value> USD)',       thin: true),
_LegendChip(color: scheme.secondary,               label: 'Outcome (<value> USD)',      thin: true),
```

- Swatch size: solid chips `width: 16, height: 2.5`; thin (Strike/Outcome) chips `height: 1.5`.
- Gap between swatch and text: 4 px.
- Text style: `Theme.textTheme.labelSmall` in `onSurfaceVariant`.
- **Strike and Outcome chips carry the numeric value with `NumberFormat.decimalPattern()` formatting and the literal `USD` suffix.** The chart title intentionally **does not** repeat those numbers — they live only in the legend.
- The dashed swatch is drawn by a tiny `CustomPainter` (`_MiniDashPainter`) for visual consistency with the canonical curve.

### 6.6 Chart painter — `_DlcPayoutChartPainter`

A single `CustomPainter` does all rendering against a 228-px-tall canvas. Pads: left 52, top 14, right 10, bottom 28.

#### On-canvas inventory (everything the user can read on the chart)

The painter draws all of the following text and geometry inside the 228 px canvas. The card title `Payout for LONG CALL` and the legend chips below sit **outside** this canvas — anything listed here is **only** the chart proper.

| Glyph | Position | Source | Style | Example |
| --- | --- | --- | --- | --- |
| **xMin label** | Bottom-left, 6 px below chart, left-aligned to `chart.left` | `_compactUsd(xMin)` | `onSurfaceVariant`, `fontSize: 10` | `65.0k` for `65 000` |
| **xMax label** | Bottom-right, 6 px below chart, right-aligned to `chart.right` | `_compactUsd(xMax)` | same | `135.0k` for `135 000` |
| **X-axis title** | Bottom-center, 6 px below chart, center-aligned | Literal `'BTC/USD (oracle)'` | same | `BTC/USD (oracle)` |
| **Y grid labels** | Right-aligned 6 px left of `chart.left`, at each `i/4` step (5 labels: `0, 1/4, 2/4, 3/4, 4/4` of the padded y-range) | `_compactSats(yVal)` | same | `1.20k`, `2.40M`, `-500`, `0` |
| **Strike guide tag** | Above the chart, just below `chart.top - 2`, horizontally centered on the strike line and clamped inside the chart | Literal `'Strike'` | `tertiary` color (alpha 0.95), `fontSize: 10`, `FontWeight.w600` | `Strike` |
| **Outcome guide tag** | Above the chart, same layout as strike tag, on the outcome line | Literal `'Expiry'` | `secondary` color (alpha 0.95), same font | `Expiry` |
| **Horizontal grid lines** | 5 lines at `i/4` steps across the plot | — | `outlineVariant` at alpha 0.35, stroke 1 | — |
| **Plot background** | Full chart rectangle | — | `surfaceContainerHighest` at alpha 0.35 | — |
| **Plot border** | Outline of the chart rectangle | — | `outlineVariant` at alpha 0.55, stroke 1 | — |
| **Strike vertical guide** | Full-height vertical line at `tx(strikeUsd)` | — | `tertiary` at alpha 0.65, stroke 1.5 | — |
| **Outcome vertical guide** | Full-height vertical line at `tx(outcomeUsd)` | — | `secondary` at alpha 0.65, stroke 1.5 | — |
| **Outcome interval band** | Translucent vertical rect across `[outcomeBand.start, outcomeBand.end]`, clipped to chart bounds | `result.outcomeInterval` | `primaryContainer` at alpha 0.28 | — |
| **Actual payout curve** | Stepped polyline across `result.intervals` (horizontal segment per interval + vertical risers) | `intervals[*].walletPayout` vs `[start, end]` | `primary`, stroke 2.2, `strokeJoin: round`, clipped to chart | — |
| **Canonical payout curve** | Dashed polyline through sorted `result.canonicalPoints` | `canonicalPoints[*].x → walletPayout` | `onSurfaceVariant` alpha 0.75, stroke 1.6, dash 7 / gap 5, clipped to chart | — |

Notes on the on-canvas tags:

- The chart shows **only** the literal words `Strike`, `Expiry`, and `BTC/USD (oracle)` plus the numeric labels above. **It deliberately does not render the strike or outcome USD values inside the canvas.** Those numbers live in the legend chips below the canvas, formatted with full grouping (`Strike (70,000 USD)`, `Outcome (75,000 USD)`).
- The y-axis has **no axis title** — the unit is communicated via the suffix in the label formatter (`-500` is sats; `1.20k` is 1,200 sats; `2.40M` is 2,400,000 sats).
- Both `_compactUsd` and `_compactSats` use 1 decimal at the `k` scale and 2 decimals at the `M`/`B` scale; values under 1,000 print as the rounded integer.
- The **bottom-left** and **bottom-right** axis labels are `_compactUsd(xMin)` and `_compactUsd(xMax)` where `xMin` / `xMax` come from the formulas in §6.6.1 below (not from the raw coordinator interval endpoints).

#### 6.6.1 X-axis bounds — formulas

Let:

- `S` = strike price in USD (integer from the simulate form, stored as `_chartStrikeUsd`)
- `O` = outcome BTC/USD at expiry (integer from the simulate form, stored as `_chartOutcomeUsd`)

The chart x-axis uses a **focused window** around strike and outcome. The coordinator may return intervals spanning the full oracle range (e.g. 0 → 999 999); these formulas crop that range so the plot centers on the kink between strike and outcome.

**Raw bounds (before clamping):**

```
xMin_raw = min(0.65 × S, 0.65 × O)
xMax_raw = max(1.35 × S, 1.35 × O)
```

**Final bounds (what the painter uses):**

```
xMin = max(0, xMin_raw)
xMax = xMax_raw   if xMax_raw > xMin
     = xMin + 1   otherwise   // degenerate guard when strike ≈ outcome
```

In code (`dlcPayoutChartStrikeOutcomeXAxis` in `dlc_option_payout_simulation.dart`):

```dart
final min = math.min(strikeUsd * 0.65, outcomeUsd * 0.65).toDouble();
var max = math.max(strikeUsd * 1.35, outcomeUsd * 1.35).toDouble();
final clampedMin = math.max(0.0, min);
if (max <= clampedMin) max = clampedMin + 1;
return (min: clampedMin, max: max);
```

| Symbol | Meaning |
| --- | --- |
| `0.65` | Lower multiplier — start the x-axis at 65 % of the **smaller** of strike and outcome, trimming flat payout below strike (calls) or far below outcome |
| `1.35` | Upper multiplier — end the x-axis at 135 % of the **larger** of strike and outcome, trimming flat payout above strike (puts) or far above outcome |
| `max(0, …)` on xMin | BTC/USD oracle price is never negative on the axis |
| Same rule for CALL and PUT | No option-type branch; one symmetric framing rule |

**Additional examples:**

| S (strike) | O (outcome) | xMin_raw | xMax_raw | xMin (final) | xMax (final) | Bottom labels |
| --- | --- | --- | --- | --- | --- | --- |
| 100 000 | 95 000 | 61 750 | 135 000 | 61 750 | 135 000 | `61.8k` · `135.0k` |
| 100 000 | 105 000 | 65 000 | 141 750 | 65 000 | 141 750 | `65.0k` · `141.8k` |
| 100 000 | 120 000 | 65 000 | 162 000 | 65 000 | 162 000 | `65.0k` · `162.0k` |
| 5 000 | 4 000 | 2 600 | 6 750 | 2 600 | 6 750 | `2600` · `6750` |

Horizontal pixel mapping inside the plot area:

```
tx(x) = chart.left + (x - xMin) / (xMax - xMin) × chart.width
```

Strike and outcome vertical guides are drawn at `tx(S)` and `tx(O)` respectively (skipped if outside `[chart.left, chart.right]` after clamping).

#### Worked example — strike 70 000 USD, outcome 75 000 USD

Inputs: `strike = 70 000`, `outcome = 75 000`. Then:

- `xMin = min(0.65 × 70 000, 0.65 × 75 000) = 0.65 × 70 000 = 45 500` → rendered as `45.5k`
- `xMax = max(1.35 × 70 000, 1.35 × 75 000) = 1.35 × 75 000 = 101 250` → rendered as `101.3k`

| What the user sees on the canvas | Exact text |
| --- | --- |
| Bottom-left label | `45.5k` |
| Bottom-right label | `101.3k` |
| Bottom-center | `BTC/USD (oracle)` |
| Strike tag (top) | `Strike` (positioned over x = 70 000) |
| Outcome tag (top) | `Expiry` (positioned over x = 75 000) |
| Legend chip 3 | `Strike (70,000 USD)` |
| Legend chip 4 | `Outcome (75,000 USD)` |
| Y labels (5 lines) | Five `_compactSats(...)` values evenly spaced across the padded payout range, e.g. `0`, `-12.5k`, `-25.0k`, `-37.5k`, `-50.0k` for a short put scenario |

#### Compact formatters used on the chart

```dart
String _compactUsd(double v) {
  if (v.abs() >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';  // e.g. "1.20M"
  if (v.abs() >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}k';  // e.g. "65.0k", "101.3k"
  return v.round().toString();                                     // e.g. "750"
}

String _compactSats(double v) {
  final r = v.round();
  final abs = r.abs();
  final sign = r < 0 ? '-' : '';
  if (abs >= 1_000_000_000) return '$sign${(abs / 1e9).toStringAsFixed(2)}B';
  if (abs >= 1_000_000)     return '$sign${(abs / 1e6).toStringAsFixed(2)}M';
  if (abs >= 1_000)         return '$sign${(abs / 1e3).toStringAsFixed(1)}k';
  return '$sign$abs';
}
```

The metric card formatters (`_formatSimSatsUnsigned`, `_formatSimSatsSigned`) are different: they use full thousand grouping (`12,345 sats`) because the metrics card has horizontal room and the user is reading exact amounts there. The compact pair above is only for the chart.

#### X axis (BTC/USD) — focused window

The most important design decision. The coordinator returns a payout curve spanning the full oracle range (often 0 → hundreds of thousands of dollars), most of which is the **flat region** below strike (for calls) or above strike (for puts). A naive plot is unreadable.

Bounds are **not** taken from `intervals[*].start` / `intervals[*].end`. They are computed solely from strike and outcome using §6.6.1:

```
xMin = max(0, min(0.65 × S, 0.65 × O))
xMax = max(1.35 × S, 1.35 × O)   // with degenerate guard if xMax ≤ xMin
```

This applies to **both** CALL and PUT charts. The strike and outcome vertical guides therefore always sit comfortably inside the viewport, and the **kink** of the option curve is the focal point.

X-axis labels (drawn in `onSurfaceVariant`, font size 10):

- Bottom-left: `_compactUsd(xMin)` → e.g. `65.0k`, `1.20M`, or raw integer below 1k.
- Bottom-right: `_compactUsd(xMax)`.
- Bottom-center: `BTC/USD (oracle)`.

#### Y axis (sats) — auto from visible data

```dart
final focusedY = dlcPayoutChartYExtentsForX(
  xMin: xMin, xMax: xMax,
  intervals: intervals,
  canonicalPoints: canonicalPoints,
);
```

`yMin/yMax` consider **only** intervals and canonical points whose x lies inside the focused x window. After scanning, an 8 % vertical pad is added so the curve never touches the chart border. If no points are visible (empty inputs) the range falls back to `0..1`.

Y labels: 5 horizontal grid lines (`i / 4`) labeled with `_compactSats(yVal)` — e.g. `1.20k`, `2.40M`, `−500`. Right-aligned, drawn 6 px to the left of the chart’s left edge.

#### Layered drawing order (back to front)

1. **Plot background.** Light fill = `surfaceContainerHighest` at alpha 0.35.
2. **Horizontal grid lines.** 5 lines, `outlineVariant` at alpha 0.35.
3. **Outcome interval band.** If the API returned `outcome_interval` (`DlcOutcomeIntervalBand`), draw a translucent vertical band across the full chart height covering `[start, end]`, clipped to chart bounds. Fill = `primaryContainer` at alpha 0.28. This visualizes the oracle bucket that contains the chosen outcome.
4. **Strike vertical guide.** `tertiary` color at alpha 0.65, stroke 1.5. Top tag “Strike” in `tertiary` / `fontSize: 10 / w600`, positioned just above the chart and horizontally centered on the guide (clamped inside the chart so it doesn’t overflow on either edge).
5. **Outcome vertical guide.** Same drawing as strike, but `secondary` color and tag `Expiry`. (Yes — internally the in-chart label is `Expiry` while the legend reads `Outcome (… USD)`. The legend is the user-facing label; “Expiry” is a compact synonym near the guide.)
6. **Clip region.** `canvas.save() + canvas.clipRect(chart)` before drawing curves so coarse intervals that extend past `xMax` don’t leak outside the plot.
7. **Actual payout (stepped).** Stepped polyline of `intervals` plotted as `(start → end)` horizontal segments with vertical risers between intervals. Stroke 2.2, color = `primary`, `strokeJoin = StrokeJoin.round`. This is the **rounded** coordinator settlement curve.
8. **Canonical payout (dashed).** `canonicalPoints` sorted by x and connected pairwise with a manual dashed line (`dashLen: 7, gapLen: 5`). Color = `onSurfaceVariant` at alpha 0.75, stroke 1.6. Represents the smooth theoretical curve before interval rounding.
9. **Restore clip.** `canvas.restore()`.
10. **Plot border.** Stroke `outlineVariant` at alpha 0.55, full chart rectangle.
11. **Axis labels.** xMin, xMax, and `BTC/USD (oracle)` along the bottom (see §6.6 X axis).

#### Why a stepped curve plus a dashed reference?

The coordinator quantizes oracle outcomes into intervals and assigns a fixed payout per interval; the actual money you receive is the **stepped** value. The smooth canonical curve is the platonic option payout the contract is approximating. Showing both side by side helps the user see (a) the shape of the option, and (b) where rounding makes a meaningful difference — quantified numerically in the metrics card by `roundingDeltaSats`.

### 6.7 Info dialogs

Two dialogs are reachable from the Simulate tab:

#### “About simulate payout” — header info icon

Triggered from the input card header. Body (exact copy):

> Use this tool to explore what payout you could receive for the role, contracts, strike, premium, and BTC/USD outcome you enter.
>
> Tapping Simulate only runs a calculation against the coordinator — no funds move, no order is placed, and nothing is signed on-chain. It is a hypothetical exercise to help you understand settlement before you trade.

Single `TextButton` action: `OK`.

#### “Rounding delta” — metric row info icon

Triggered by the (i) button on the `Rounding delta` metric. Body (exact copy):

> The coordinator expresses DLC payouts as a stepped curve: oracle outcomes are grouped into intervals, and each interval has a fixed wallet payout (see the chart).
>
> Rounding delta is the gap between that stepped (rounded) payout and the smooth theoretical payout at the same BTC/USD price — in other words, how much interval rounding moves your settlement versus the ideal curve.
>
> Positive means the rounded payout is higher than the canonical value at this outcome; negative means it is lower.

Single `TextButton` action: `OK`.

### 6.8 Simulation results card

Header: `Icons.receipt_long_outlined` + “Simulation results” (`titleMedium`, w600).

The body is a list of `_SimulateMetricRow` widgets. Each row has:

- Left: label (`bodyMedium`, `onSurface`). May include a trailing (i) icon button.
- Right: value, right-aligned. When `emphasize: true`, weight `w700` + `primary` color (default) or a custom `valueColor`.

Row spec, in render order (one row each):

| Row label | Value source | Formatter | Notes |
| --- | --- | --- | --- |
| `PnL (rounded)` | `roundedPnlSats` | `_formatSimSatsSigned` | `emphasize: true`. Color via `_simulationPnlValueColor`: error if negative; in light mode dark green `#1B5E20`, in dark mode `#81C784` if non-negative. |
| `PnL (no fees incl.)` | `roundedPnlSats + networkFeeSats + walletFeeSats` | `_formatSimSatsSigned` | Same green/red rule. Helps users see PnL before deducting fees. |
| `Posted collateral` | `walletPostedCollateralSats` | `_formatSimSatsUnsigned` | |
| `Premium paid (upfront)` | `premiumPaidUpfrontSats` | `_formatSimSatsUnsigned` | |
| `Premium received (upfront)` | `premiumReceivedUpfrontSats` | `_formatSimSatsUnsigned` | |
| `Premium embedded in DLC` | `premiumEmbeddedInDlcSats` | `_formatSimSatsUnsigned` | |
| `Rounded settlement payout` | `walletRoundedSettlementPayoutSats` | `_formatSimSatsUnsigned` | |
| `Canonical payout` | `walletCanonicalPayoutSats` | `_formatSimSatsUnsigned` | |
| `Network fees` | `networkFeeSats` | `_formatSimSatsUnsigned` | |
| `Wallet/service fees` | `walletFeeSats` | `_formatSimSatsUnsigned` | |
| `Total fees` | `totalFeeSats` | `_formatSimSatsUnsigned` | |
| `Rounding delta` | `roundingDeltaSats` | `_formatSimSatsSigned` | Label has trailing (i) icon → opens the **Rounding delta** dialog (§6.7). |

#### Formatters

```dart
String _formatSimSatsUnsigned(int sats) =>
    '${NumberFormat.decimalPattern().format(sats)} sats';      // e.g. "12,345 sats"

String _formatSimSatsSigned(int sats) {
  final fmt = NumberFormat.decimalPattern();
  if (sats == 0) return '${fmt.format(0)} sats';
  final sign = sats > 0 ? '+' : '';
  return '$sign${fmt.format(sats)} sats';                       // e.g. "+12,345 sats" / "-12,345 sats"
}
```

The signed formatter is reserved for PnL rows and the rounding delta; everything else is unsigned (these values are conceptually amounts, not changes).

### 6.9 Request and response contract (recap)

Request payload sent in `POST /orders/option-payout-simulation`:

```json
{
  "side": "buy",                   // from buyer/seller segmented button
  "role": "maker",                 // from Maker/Taker segmented button
  "option_right": "C",             // "C" for CALL, "P" for PUT
  "num_contracts": 1.0,
  "strike": 70000,                 // integer USD
  "premium_per_contract_sats": 12345,
  "outcome_price": 75000,          // integer USD
  "premium_paid_upfront": true,    // fixed
  "network_fee_sats": 0,
  "num_digits": 8                  // fixed
}
```

Response fields the UI consumes (parsed into `DlcOptionPayoutSimulationResult`):

| Response field | UI usage |
| --- | --- |
| `rounded_pnl_sats` | `PnL (rounded)` row and the derived `PnL (no fees incl.)` row |
| `canonical_pnl_sats` | Not currently displayed (kept on the model) |
| `wallet_posted_collateral_sats` | `Posted collateral` row |
| `premium_paid_upfront_sats` | `Premium paid (upfront)` row |
| `premium_received_upfront_sats` | `Premium received (upfront)` row |
| `premium_embedded_in_dlc_sats` | `Premium embedded in DLC` row |
| `wallet_rounded_settlement_payout_sats` | `Rounded settlement payout` row |
| `wallet_canonical_payout_sats` | `Canonical payout` row |
| `network_fee_sats` | `Network fees` row + included in “(no fees incl.)” derivation |
| `wallet_fee_sats` | `Wallet/service fees` row + included in “(no fees incl.)” derivation |
| `total_fee_sats` | `Total fees` row |
| `rounding_delta_sats` | `Rounding delta` row |
| `intervals[]` | Stepped curve segments on the chart |
| `canonical_points[]` | Dashed reference curve on the chart |
| `outcome_interval` | Highlighted vertical band on the chart |

### 6.10 Design rationale — implementer notes

- **Tab works without wallet auth.** This is the most viewed tab for new users. Forcing activation just to see what an option pays would kill exploration. The coordinator endpoint allows it; the UI honours that.
- **Captured chart snapshot.** Storing `_chartStrikeUsd` / `_chartOutcomeUsd` at submit time prevents the chart from sliding around as the user types new inputs — the chart describes the **last simulated** scenario, the form describes the **next** one.
- **Auto-scroll to chart, not to results.** After simulate, the chart is the focal point. The metrics card sits below it and is reached by a short swipe. The 0.08 viewport-top alignment keeps a sliver of the input card visible so the user still recognizes their inputs.
- **Inline error vs SnackBar.** Validation failures (sync) are SnackBars (transient, no clutter on retry). API/network failures are persistent inline banners inside the input card **and** a SnackBar, because the user may need to copy the error or scroll up to see it.
- **Conversational layout.** The inline-sentence form deliberately reads like a request a trader would speak. Each `Wrap` collapses gracefully on narrow widths so the layout still looks like a sentence on small phones.
- **Why segmented buttons for everything categorical.** Three independent two-option dimensions (long/short, put/call, maker/taker) are common in options trading. Dropdowns would hide state; segmented controls keep all three visible.
- **`70000` fallback.** A round, conservative number high enough not to look broken at any plausible spot. Updated automatically as soon as the ticker URL responds.
- **No spinner inside the SIMULATE button.** The shared `DlcActionLoadingOverlay` already covers the screen during the request, so an inline spinner would be redundant. The button only goes `onPressed: null` while `_loading`.
- **Chart x-axis rule symmetric across PUT/CALL.** The same `min(0.65×, …)` / `max(1.35×, …)` formula works for both, because in either case the **interesting** part of the curve sits between strike and outcome, and the multipliers crop the flat tail by definition. Previously the code branched on option type with custom margins; the symmetric rule is simpler and produces visually equivalent results.
- **Strike/Outcome values live only in the legend.** Earlier iterations put them in the chart title (`Payout for LONG CALL, Strike: 100,000 USD`); this made the title long, especially on small phones, and duplicated the vertical guide. The chips beneath the chart now carry the value, the title stays compact.

### 6.11 Files

| Concern | Path |
| --- | --- |
| Input form + result cards | `lib/features/dlc/ui/screens/dlc_home_screen.dart` (`_SimulateTabPanel*`, `_SimulateMetricRow`, `_simulatePayoutCurveTitle`, `_formatSim*`, `_simulationPnlValueColor`) |
| Chart widget + legend chips | `lib/features/dlc/ui/widgets/dlc_option_payout_chart.dart` (`DlcOptionPayoutChart`, `_LegendChip`, `_DlcPayoutChartPainter`) |
| Chart axis math | `lib/features/dlc/domain/dlc_option_payout_simulation.dart` (`dlcPayoutChartStrikeOutcomeXAxis`, `dlcPayoutChartFocusedXExtents`, `dlcPayoutChartYExtentsForX`) |
| Request/response models | `lib/features/dlc/domain/dlc_option_payout_simulation.dart` (`DlcOptionPayoutSimulationRequest`, `DlcOptionPayoutSimulationResult`, `DlcPayoutInterval`, `DlcCanonicalPoint`, `DlcOutcomeIntervalBand`) |
| Repository call (no auth required) | `lib/features/dlc/data/dlc_repository.dart` (`simulateOptionPayout`) |
| Datasource HTTP | `lib/features/dlc/data/dlc_api_datasource.dart` (`simulateOptionPayout`) |
| Tests | `test/features/dlc/domain/dlc_option_payout_simulation_test.dart` (parsing + axis math) |

---

## 7. State contract (`DlcState`)

Minimum fields the UI expects:

| Field | UI consumers |
| --- | --- |
| `loading` | Initial catalog load; disables inputs |
| `actionInProgress` | Blocking overlay |
| `processingOrder` | Disables cancel buttons |
| `auth` | Gate for create, own-order highlighting, balances |
| `instruments` | Instrument picker, filtering by option type |
| `orders` | My Orders, overview counts, own-order book marks |
| `selectedInstrumentId` | Trade tab template id |
| `optionType` | Call/put filter |
| `side`, `quantity`, `price`, `strikePrice` | Create form |
| `suggestedStrikePrices`, `btcUsdSpotPrice` | Strike dropdown |
| `strikeOrderbooks` | Summary table |
| `totalBalanceSat`, `availableBalanceSat`, `reservedBalanceSat` | Overview bar |
| `walletPnlSats` | Overview PnL card |
| `coordinatorTradingHint` | Warning banner (Overview; also affects Trade) |
| `errorMessage`, `infoMessage` | Banners |
| `selectedTabIndex` | Tab bar |
| `registeredWalletAuths`, `expiredWallets`, `availableWallets` | Activation UI |
| `createOrderMatchIntent` | Optimistic create UX (cleared after create) |

---

## 8. Cubit methods the UI must call

| User action | Cubit method |
| --- | --- |
| App open | `load()` |
| Pull refresh | `refreshCurrentTab()` |
| Pick registration wallet | `setRegistrationWallet(id)` |
| Activate / register | `activateWalletForDlc(id)` |
| Switch wallet (dialog) | `activateWalletForDlc(id)` |
| Tab change | `setTab(index)` |
| Trade side | `setSide` |
| Strike | `setStrikePrice` |
| Quantity / premium | `setQuantity`, `setPrice` |
| Create | `createOrder()` |
| Cancel | `cancelOpenOrder(id)` |
| Orderbook depth tap | `applyCreateOrderFromOrderbookDepth(...)` |
| Instrument change | `selectOptionInstrumentAndStrike` / `selectInstrumentAndStrike` |
| Dismiss banner | `clearTransientMessages()` |

---

## 9. UX principles for a polished wallet client

### 9.1 Optimistic UI where safe

- **Do:** Show pending order immediately on create; switch to My Orders tab.
- **Do:** Trim orderbook locally on match-intent create.
- **Don’t:** Optimistically mark accept/sign complete — cryptographic work must confirm with coordinator.

### 9.2 Never block the app during signing

Accept/sign run in repository background worker + compute isolate. Show hourglass + explanatory dialog, not a modal spinner for 60+ seconds.

### 9.3 Explain coordinator vs wallet semantics

Copy should repeatedly clarify:

- Coordinator balance ≠ full wallet balance
- Premium field on create is informational when `price: null` on API
- “Filled” ≠ economically settled
- Exact quantity matching only

### 9.4 Selectable identifiers

Order IDs and diagnostic values use `SelectableText` in detail dialogs — support staff and power users copy ids.

### 9.5 Accessibility and touch targets

- Tab bar: ~13px vertical padding + icon → ~48dp effective height
- Order row icon buttons: `VisualDensity.compact` but min 32–36dp constraints
- Segmented buttons on Simulate: explicit compact style with min height 34

### 9.6 Adapt to host wallet style

When porting to another app:

1. Replace `DlcActionLoadingOverlay` GIF with host wallet’s standard loading pattern.
2. Map green/red semantics to host semantic colors if brand palette differs.
3. Keep Card-based section hierarchy — works with Material 3 light/dark.
4. Place DLC entry in host nav (drawer tab, bottom nav item) pointing to single `/dlcs` route.
5. Reuse host’s existing Bitcoin wallet picker component instead of raw dropdown if available.

---

## 10. End-to-end UI ↔ API flow diagrams

### 10.1 First visit → first trade

```text
Open /dlcs
  → load() → GET /instruments, GET /readiness
  → Overview: user picks wallet → Activate
  → POST /auth/nonce, POST /auth/wallet, sync-utxos
  → Trade: pick strike from orderbook → fill form → Create
  → optimistic row in My Orders
  → POST /orders (background)
  → if match: accept-context → sign locally → accept-match
  → if maker: sign-context → sign locally → POST /dlcs/sign
  → row moves Open → Live → Closed; hourglass disappears
```

### 10.2 Simulate only (no wallet)

```text
Open /dlcs → Simulate tab
  → fill scenario → SIMULATE
  → POST /orders/option-payout-simulation
  → chart + metrics (no auth required; partner token still sent)
```

---

## 11. Checklist for implementers

- [ ] Single route, four-tab shell with shared banners, refresh, overlay
- [ ] Overview activation gate before create
- [ ] Trade: multi-strike orderbook summary + depth dialog + create form
- [ ] Create: optimistic pending order + tab switch + background API
- [ ] My Orders: three sections with correct bucketing rules
- [ ] In-flight phases with hourglass + dialogs (no blocking overlay for sign)
- [ ] Simulate: isolated form, chart, metrics; clearly labeled hypothetical
- [ ] Pull-to-refresh per tab
- [ ] 15s background negotiation poll when orders need work
- [ ] Coordinator hint banner for config/network issues
- [ ] Buy/sell color semantics and fee/settlement copy
- [ ] All HTTP/signing behind repository — UI talks to cubit only

---

## 12. Related code entry points

| Topic | File |
| --- | --- |
| Tab shell + all panels | `lib/features/dlc/ui/screens/dlc_home_screen.dart` |
| Cubit orchestration | `lib/features/dlc/presentation/dlc_cubit.dart` |
| State shape | `lib/features/dlc/presentation/dlc_state.dart` |
| Order section rules | `lib/features/dlc/domain/dlc_order_in_flight.dart` |
| Payout chart painter | `lib/features/dlc/ui/widgets/dlc_option_payout_chart.dart` |
| API integration detail | [WALLET-API-INTEGRATION-GUIDE_BULLBITCOIN.md](./WALLET-API-INTEGRATION-GUIDE_BULLBITCOIN.md) |
