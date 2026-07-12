# Claude Pulse — Rebuild Spec (combined subscription + API UI)

Forward-looking spec for rebuilding the app with a UI that can show **subscription
limits and API/local spend together** (or either alone). It builds on the as-built
mechanics in [ARCHITECTURE.md](ARCHITECTURE.md); read that first for the exact
formulas, constants, and data shapes. This file specifies only what's *new or
generalized* for the rebuild.

Doc set: [DESIGN.md](DESIGN.md) = *why* · [ARCHITECTURE.md](ARCHITECTURE.md) =
*what/how, as-built* · **REBUILD.md (this) = forward spec**.

> Never commit secrets here (API keys, OAuth tokens, credential values).

---

## 1. Data-availability model (replaces "two exclusive modes")

The shipped app picks one display mode per credential (DESIGN.md §4). That's a
display choice, not a data limit. The two limit systems are disjoint *pools*, but
the **data you can show is additive per auth state** — a machine can surface
several pillars at once. Treat the UI as composing independent **pillars**, each
present only when its source is:

| Pillar | Source | Present when |
|---|---|---|
| **P1 Subscription windows** (5h/7d %, resets) | claude.ai OAuth `/oauth/usage` | OAuth-JSON credential in Keychain |
| **P2 Local Claude Code usage** (tokens, credits, model mix, activity) | local JSONL | **always** (any auth, even none) |
| **P3 Local spend estimate** (USD, this machine CC) | local JSONL × pricing | **always** |
| **P4 Org spend & token usage** (USD + tokens, all keys/workspaces) | Admin Usage & Cost API | user supplies an Admin key (org account) |
| **P5 Prepaid balance** | — | **never** (no endpoint; see §3.4) |

Availability by credential state:

| Keychain state | P1 | P2 | P3 | P4 | Notes |
|---|:--:|:--:|:--:|:--:|---|
| OAuth-JSON (subscription) | ✅ | ✅ | ✅ | ➕ if Admin key | Combined view: windows + local spend, optionally org spend |
| `sk-ant` API key | ❌ | ✅ | ✅ | ➕ if Admin key | Spend-first view; P1 doesn't exist for this billing |
| none / denied | ❌ | ✅ | ✅ | ➕ if Admin key | Local-only estimate |

(For how auth mode / plan is detected from the Keychain, see ARCHITECTURE.md §2.)

**Consequences for a combined UI:**
- P1 and P4 are the two authoritative pillars and are **never both maximally
  meaningful on the same account** (subscription vs. API billing), but a machine
  *can* have P1 (its own subscription login) while the org also has API spend
  (P4) — show both, clearly labeled by pool.
- P3 (local spend) is always available and is the natural bridge: it renders on a
  subscription machine too, as "estimated value of this machine's CC usage"
  (with the caveat in ARCHITECTURE.md §7 that subscription usage isn't billed
  per-token).
- The old auth-mode gate becomes a **layout hint**, not a data filter: pick a
  primary pillar (P1 if present, else P3/P4) but let the UI show the rest.

## 2. Local spend pillar (P3) — generalize the cost engine

The shipped code computes cost only for the 5h and weekly windows
(ARCHITECTURE.md §5). A spend UI needs cost over **arbitrary ranges**. Generalize
`UsageCalculator` to expose:

```
spend(range: DateInterval) -> SpendBreakdown {
    totalUSD: Double
    byModel: [modelId: Double]
    byComponent: { input, output, cacheWrite5m, cacheWrite1h, cacheRead: Double }
    inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens: Int
    messageCount: Int
}
```
- Same per-message `cost(for:)` (ARCHITECTURE.md §5), summed over entries in
  `range`. Reuse the ARCHITECTURE.md §4.1 preprocessing (assistant+usage only,
  **dedup by `requestId`**, sorted).
- Suggested standard ranges: **today** (local midnight), **rolling 24h**,
  **this week** (7d rolling and/or calendar), **this month** (calendar),
  **all-time**. Ranges are just `DateInterval`s — no new parsing.
- This is CC-on-this-machine only. It is an **estimate** using public API pricing;
  label it as such. For org-wide/actual billed cost use P4.

## 3. API / prepaid path (P4) — full Admin Usage & Cost API spec

Verified against Anthropic docs, **2026-07**. This is the concrete spec for the
unbuilt API panel.

### 3.1 Auth & preconditions
- **Base URL:** `https://api.anthropic.com`
- **Header:** `x-api-key: <sk-ant-admin01-…>` **or**
  `authorization: Bearer <oauth token with org:admin scope>`; plus
  `anthropic-version: 2023-06-01`. Set a `User-Agent: ClaudePulse/x.y (url)`.
- **Requires an organization account** — "unavailable for individual accounts."
  Admin keys are created in Console by an admin-role member. **Surface this in
  Settings** so an individual account's key doesn't silently 4xx.
- Distinct from the normal `sk-ant-api03-…` inference key. Enterprise (claude.ai)
  orgs use a different **Analytics API key** instead — out of scope unless needed.
- **Not available on Claude Platform on AWS** (Console UI only there).
- **Freshness ~5 min**; poll **≤ once/min** (cache like the 60s OAuth cache).

### 3.2 Token usage — `GET /v1/organizations/usage_report/messages`
Query params (all optional except `starting_at`):
- `starting_at` (RFC 3339, snapped to UTC bucket start), `ending_at`
- `bucket_width`: `1m` | `1h` | `1d`
- `limit` (buckets): `1d` default 7/max 31 · `1h` 24/168 · `1m` 60/1440
- `page` (pagination cursor, see §3.5)
- Filters (arrays): `models[]`, `api_key_ids[]`, `workspace_ids[]`,
  `account_ids[]`, `service_account_ids[]`, `service_tiers[]`
  (`standard|batch|flex|flex_discount|priority|priority_on_demand`),
  `context_window[]` (`0-200k|200k-1M`), `inference_geos[]`
  (`global|us|not_available`), `speeds[]` (`standard|fast`, needs
  `anthropic-beta: fast-mode-2026-02-01`)
- `group_by[]`: any of `model, api_key_id, workspace_id, account_id,
  service_account_id, service_tier, context_window, inference_geo, speed`

Response:
```jsonc
{
  "data": [{
    "starting_at": "2025-08-01T00:00:00Z",   // inclusive, RFC 3339
    "ending_at":   "2025-08-02T00:00:00Z",   // exclusive
    "results": [{                             // multiple if group_by[] set
      "uncached_input_tokens": 1500,
      "cache_creation": { "ephemeral_1h_input_tokens": 1000,
                          "ephemeral_5m_input_tokens": 500 },
      "cache_read_input_tokens": 200,
      "output_tokens": 500,
      "server_tool_use": { "web_search_requests": 10 },
      "model": "claude-opus-4-6",             // null unless grouped
      "workspace_id": "wrkspc_…",             // null = default workspace / not grouped
      "api_key_id": "apikey_…",               // null for Console/Workbench usage
      "account_id": "user_…", "service_account_id": "svac_…",
      "service_tier": "standard", "context_window": "0-200k",
      "inference_geo": "global"
    }]
  }],
  "has_more": true,
  "next_page": "<cursor>"
}
```
Note the token field names **differ from JSONL**: `uncached_input_tokens` here vs.
`input_tokens` in JSONL, but `cache_creation.ephemeral_{5m,1h}_input_tokens` and
`cache_read_input_tokens` match. Sum across `results` per bucket for totals.

### 3.3 Cost (USD) — `GET /v1/organizations/cost_report`
Params: `starting_at` (req), `ending_at`, `bucket_width` = `1d` **only**, `limit`,
`page`, `group_by[]` ∈ `{workspace_id, description}`.
```jsonc
{
  "data": [{
    "starting_at": "2025-08-01T00:00:00Z",
    "ending_at":   "2025-08-02T00:00:00Z",
    "results": [{
      "amount":   "123.78912",   // DECIMAL STRING, lowest units (cents): /100 = USD
      "currency": "USD",
      "cost_type": "tokens",     // tokens|web_search|code_execution|session_usage
      "description": "Claude Sonnet 4 Usage - Input Tokens", // null unless grouped
      "model": "claude-opus-4-6",            // null unless grouped by description
      "token_type": "uncached_input_tokens", // cache_creation.*|cache_read_input_tokens|output_tokens|uncached_input_tokens
      "context_window": "0-200k",
      "service_tier": "standard",            // standard|batch
      "workspace_id": "wrkspc_…"             // null = default / not grouped
    }]
  }],
  "has_more": true, "next_page": "<cursor>"
}
```
- **`amount` is a decimal string in cents** — parse as Decimal, `/100` for USD.
  Sum all `results` across all buckets for total spend over the range.
- **Priority-Tier costs are excluded** from cost_report — track those via the
  usage endpoint's `service_tier=priority`.
- For **per-user Claude Code cost**, there's a dedicated Claude Code Analytics API
  (better than grouping cost by many keys) — note as a future option.

### 3.4 The balance gap (P5) → user budget
There is **no endpoint for remaining prepaid balance** anywhere; it's Console-UI
only. So the API panel shows **cumulative spend**, never a true remaining balance.
To give a "remaining" feel, let the user optionally enter a **starting balance or
monthly budget** in Settings and compute `budget − Σ cost_report(amount)`. Label
it clearly as budget-relative, not an authoritative balance.

### 3.5 Pagination, caching, errors
- Loop: request → if `has_more`, resend with `page = next_page` → until false.
  Accumulate `data[].results` across pages.
- Cache responses (≥60s); the data only refreshes ~every 5 min server-side.
- Handle: 401/403 (bad/insufficient key → prompt re-entry, flag org requirement),
  429 (back off), non-org account (surface the "requires organization" message).
- **Rate limits (RPM/TPM/TPD):** only *configured* ceilings are readable (separate
  Rate Limits API, same Admin key). Live per-minute usage is only in Messages API
  `anthropic-ratelimit-*` response headers, which this app never sees. Don't
  promise a live rate-limit gauge.

## 4. Unified engine contract (UI-agnostic view model)

To let *any* UI compose the pillars, the rebuild should split the calc layer from
presentation and publish one plain snapshot. The shipped `WindowUsage` conflates
authoritative API fields, local estimates, and display formatting — the new model
separates them by provenance so the UI decides what to trust and show.

```
UsageSnapshot {
  capturedAt: Date
  auth: { mode: subscription|apiKey|unknown|adminKeyPresent, plan: ClaudePlan? }

  // P1 — nil unless OAuth usage available. Authoritative, all-surfaces.
  subscription: {
    fiveHour:  Window { percent: 0…1, resetsAt: Date }
    sevenDay:  Window { percent: 0…1, resetsAt: Date }
    source: .authoritativeAPI
  }?

  // P2 — always. This machine's Claude Code, from JSONL.
  localUsage: {
    fiveHourWindow: { start, end: Date; credits, creditCap: Double;
                      inputTokens, outputTokens, cacheCreationTokens,
                      cacheReadTokens: Int; percentOfCap: 0…1; isActive: Bool }
    weekly: { … same shape, 7d cap … }
    source: .localEstimate            // cache-exclusive credits (ARCHITECTURE §3)
  }

  // P3 — always. Spend estimate over standard ranges (§2).
  localSpend: { byRange: [Range: SpendBreakdown]; source: .localEstimate }

  // P4 — nil unless Admin key configured (§3).
  orgUsage: { tokensByRange: […]; source: .adminAPI }?
  orgSpend: { usdByRange: [Range: Decimal]; budget: Decimal?; source: .adminAPI }?
}
```

Rules the UI relies on:
- **Provenance tag on every pillar** (`authoritativeAPI` / `localEstimate` /
  `adminAPI`) so estimates render visually distinct from authoritative numbers.
- **No back-solving inside the model.** The shipped `displayCredits`
  (`percent × cap`) and the residual (`percentUsed − cliPercentUsed`) —
  ARCHITECTURE.md §6 — are *presentation* transforms — compute them in the UI
  from `subscription` + `localUsage`, don't bake them in. Keep the raw inputs so a
  different UI can choose a different decomposition.
- **Pillars are independently nil-able** — a combined view renders whatever is
  present; a minimal view picks one. Same snapshot, many layouts.
- Headline selection is a UI policy: prefer `subscription.fiveHour.percent` when
  present, else `localUsage.fiveHourWindow.percentOfCap`, and always allow a spend
  headline (`localSpend`/`orgSpend`) as an alternate primary tile.

---

## 5. Rebuild checklist

### A. Reproduce the shipped subscription/local path (per ARCHITECTURE.md)
1. **Recursive JSONL load** from `~/.claude/projects/**/*.jsonl`, assistant+usage
   only, **dedup by `requestId`**, ISO8601 dates with/without fractional seconds.
   (ARCHITECTURE §1.1, §4.1)
2. **Rolling 5h & 7d window detection** (advance start on >window-duration gap;
   10-day weekly lookback cap; expired-window → empty session). (ARCHITECTURE §4)
3. **Credit formula** `ceil(in×rate + out×rate)` with the ARCHITECTURE §3.1 rates,
   cache **excluded**; caps per §3.2; Pro default.
4. **Cost formula** per ARCHITECTURE §5 with TTL-split cache handling.
5. **Keychain read**: 3 service names in order, OAuth-JSON only, reject `sk-ant`,
   5-min back-off on denial; plan + auth-mode detection. (ARCHITECTURE §2)
6. **API overlay**: fetch first, per-window independent fallback, `hasAPIData`
   flag. (ARCHITECTURE §6)
7. **Calibration logging** — and, new: the fitter that consumes it.
   (ARCHITECTURE §7)
8. **State thresholds** (0.70/0.90, idle if inactive) and, if you keep the shipped
   layout, the residual row `max(0, percentUsed − cliPercentUsed)`.
   (ARCHITECTURE §9, §6)
9. **Notifications** (once-per-window 70/90 with re-arm, reset detection).
   (ARCHITECTURE §9)
10. **Widget parity** — decide whether it shares plan/API state (App Group) or
    stays the local-only Pro-capped estimate it is today. (ARCHITECTURE §10)

### B. New for the combined subscription + API UI
11. **Pillar model** (§1) — compute P1–P4 independently; each nil-able; tag
    provenance. Retire the auth-mode-as-filter gate; make it a layout hint.
12. **Generalized local spend** (§2) — `spend(range:)` over today/24h/week/month/
    all-time from the same JSONL preprocessing.
13. **Admin Usage & Cost API client** (§3) — Admin-key/OAuth auth, both endpoints,
    pagination loop, `amount`-cents parsing, ≥60s cache, org-required + non-AWS +
    error handling, Settings field with the "organization account" caveat.
14. **Budget-relative spend** (§3.4) — optional user balance/budget minus
    cumulative `cost_report` spend; never labeled as authoritative balance.
15. **`UsageSnapshot` view model** (§4) — split calc from presentation; move
    `displayCredits`/residual into the UI layer; publish one plain snapshot.
16. **Combined layout policy** — headline selection, side-by-side pillars, and
    consistent estimate-vs-authoritative styling driven by the provenance tags.
