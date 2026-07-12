# Claude Pulse — Calculation Architecture (as-built)

This document captures **how the subscription and API usage numbers are computed
in the shipped app** — every data source, where it lives, the exact formulas and
constants, how accurate each figure is, and the inherent limitations. It is the
authoritative *what/how* reference: a new implementation should be able to
reproduce the current numbers from this file alone.

Doc set:
- [DESIGN.md](DESIGN.md) — *why* (goals, decisions, rationale).
- **ARCHITECTURE.md (this)** — *what/how*, as-built mechanics.
- [REBUILD.md](REBUILD.md) — *forward spec* for a rebuild whose UI shows
  subscription **and** API/spend together (pillar model, generalized spend, full
  Admin Usage & Cost API spec, UI-agnostic engine contract, rebuild checklist).

When DESIGN and ARCHITECTURE appear to disagree on mechanics, this file wins.

> Never commit secrets here (API keys, OAuth tokens, credential values).

---

## 0. TL;DR of the two systems

Anthropic enforces **two disjoint limit systems**. The shipped app authenticates
one way at a time, so a machine is in exactly one mode. (A rebuild can show data
from both at once — see [REBUILD.md §1](REBUILD.md).)

| | Subscription (Pro/Max) | API / prepaid credits |
|---|---|---|
| Limit shape | 5-hour rolling window + 7-day window, **% utilization** | Per-minute rate limits (RPM/TPM/TPD) + prepaid balance |
| Shared across | **all** subscription surfaces (web, desktop, mobile, CC) | per-org API usage |
| Authoritative source | claude.ai OAuth usage endpoint (`utilization` %) | Admin/Console Usage & Cost API (spend, not balance) |
| Credential | OAuth-JSON in Keychain | `sk-ant-…` API key |
| App's current support | implemented (subscription panel) | **not built** — falls back to local estimate |

The two pools do **not** mix. There is **no** 5-hour/weekly window for API-key
billing, and **no** live credit-balance endpoint anywhere.

---

## 1. Data sources & exact locations

### 1.1 Local JSONL — this machine's Claude Code only
- **Location:** `~/.claude/projects/**/*.jsonl` (recursive; includes `subagents/`
  subdirs). Loaded in `UsageEngine.loadAllEntries` / `jsonlFiles(under:)`.
- **Gives:** input/output token counts, cache-creation & cache-read tokens,
  per-model mix, timestamps, USD cost estimate, activity detection.
- **Scope:** ONLY Claude Code on **this** machine. Not web, not mobile, not other
  machines, not the Claude desktop app.
- **Parsed by:** `JSONLParser` → `[JSONLEntry]`.
- **Watched by:** `FileWatcher` (FSEvents) → debounced 500ms refresh, plus a 60s
  countdown timer.

Relevant JSONL entry shape (only the fields the app reads):
```jsonc
{
  "type": "...",
  "timestamp": "<ISO8601, with or without fractional seconds>",
  "requestId": "<dedup key>",
  "message": {
    "role": "assistant",          // only assistant msgs with usage are counted
    "model": "claude-opus-4-8",
    "usage": {
      "input_tokens": 123,
      "output_tokens": 456,
      "cache_creation_input_tokens": 789,   // total write (legacy/back-compat)
      "cache_read_input_tokens": 1011,
      "cache_creation": {                    // TTL split (newer logs)
        "ephemeral_5m_input_tokens": 100,
        "ephemeral_1h_input_tokens": 689
      }
    }
  }
}
```

### 1.2 claude.ai OAuth usage endpoint — authoritative, all-surfaces
- **URL:** `https://claude.ai/api/oauth/usage`
- **Auth:** `Authorization: Bearer <accessToken>` from the OAuth-JSON credential.
- **Gives:** the authoritative subscription **`utilization` percentage** (0–100)
  and `resets_at` for the 5-hour and 7-day windows. **Aggregate only — never
  itemized by surface.**
- **Scope:** ALL subscription surfaces combined.
- **Client:** `UsageAPIClient.fetchUsage()`. Cached 60s; returns `nil` (no throw)
  when no OAuth credential exists.

Response shape (as of June 2026):
```jsonc
{
  "five_hour": { "utilization": 21.0, "resets_at": "<ISO8601>" },
  "seven_day": { "utilization":  7.0, "resets_at": "<ISO8601>" }
}
```
Decoded into `APIUsageData { fiveHour: RateLimitWindow?, sevenDay: RateLimitWindow? }`
where `RateLimitWindow { usedPercentage: 0–100, resetsAt: Date }`. `utilization`
is accepted as either Double or Int. Dates parse with **and** without fractional
seconds.

### 1.3 Anthropic Admin / Console Usage & Cost API — future, org-wide
- **Not implemented.** For the planned API-key mode. **Full spec:**
  [REBUILD.md §3](REBUILD.md).
- `GET /v1/organizations/usage_report/messages` — token usage (uncached/cached
  input, cache-creation, output), grouped by model/workspace/key/tier/etc.,
  `1m`/`1h`/`1d` buckets.
- `GET /v1/organizations/cost_report` — USD spend, `1d` only.
- **Auth:** `sk-ant-admin01-…` in `x-api-key` (distinct from `sk-ant-api03-…`), OR
  OAuth bearer with `org:admin`. **Requires an organization account** —
  unavailable for individuals. Freshness ~5 min; poll ≤ 1/min.
- **Rate Limits API** (separate): reads *configured* RPM/TPM/TPD only.
- ❌ **No prepaid-balance endpoint anywhere.** Balance is Console-UI-only. The
  API yields **spend**, never remaining balance.

---

## 2. Credentials (Keychain) — how auth mode & plan are detected

`UsageAPIClient.readToken()` reads a **generic-password** item, trying these
services **in order**, matching by **service only** (account = system username is
not hardcoded):

1. `Claude Code`            (current, Claude Code 2.x)
2. `claude.ai`             (claudeai-proxy transport)
3. `Claude Code-credentials` (legacy)

Payload handling:
- **OAuth-JSON** `{ "claudeAiOauth": { "accessToken": "...", "rateLimitTier": "...", "subscriptionType": "..." } }`
  → subscription mode. Token also accepted at top level under
  `accessToken`/`access_token`/`token`, or nested under `claudeAiOauth`.
- **Plaintext `sk-ant…`** → recognized as **API-key mode** and **deliberately
  ignored** (never sent as a bearer token to `/oauth/usage` — wrong credential
  type and a misuse risk). Sets `detectedAuthMode = .apiKey`.
- Nothing readable under any name → `detectedAuthMode = .unknown`.
- `errSecUserCanceled` / `errSecInteractionNotAllowed` → back off **5 minutes**
  (`keychainDeniedUntil`) so the app doesn't hammer prompts.

`AuthMode ∈ { subscription, apiKey, unknown }` drives which panel to render.

### Plan detection (`detectPlan`)
From the OAuth-JSON `claudeAiOauth` object, most-specific first:
- `rateLimitTier`: contains `"20"` → Max20; contains `"5"` → Max5; `"default"`
  or `"pro"` → Pro.
- else `subscriptionType`: contains `"20"` → Max20; contains `"max"` → Max5
  (max w/o number ⇒ assume Max5); `"pro"` → Pro.
- else `nil` → let the user's manual setting stand, caps default to **Pro**.

Empirical mapping: `"default"` → Pro, `"max_5x"` → Max5, `"max_20x"` → Max20.

---

## 3. The credit model (subscription)

The subscription limit is modeled locally as **credits**. This is the app's own
model of Anthropic's opaque limit; the API only returns a %.

```
credits_per_message = ceil(input_tokens × input_rate + output_tokens × output_rate)
```

**Cache tokens are excluded by design** — cache reads are free on subscription;
cache creation is *assumed* free here but probably isn't (see §7).

### 3.1 Per-model credit rates (`CreditRates`, source: she-llac.com/claude-limits)
| Model match | input rate | output rate |
|---|---|---|
| `haiku` | 0.133 | 0.667 |
| `sonnet` (default) | 0.4 | 2.0 |
| `opus` | 0.667 | 3.333 |
| `fable`/`mythos` | 0.667 | 3.333 *(unconfirmed — using opus as lower bound)* |
| unknown | 0.4 | 2.0 (sonnet) |

Model matching is substring-based on the model string.

### 3.2 Caps (`UsageCalculator`, source: she-llac.com/claude-limits)
| Plan | Session (5h) cap | Weekly (7d) cap |
|---|---|---|
| Pro | 550,000 | 5,000,000 |
| Max 5× | 3,300,000 | 41,666,700 |
| Max 20× | 11,000,000 | 83,333,300 |

Defaults when plan unknown: **Pro** caps. These caps are **unofficial** and are
the primary calibration target (§7).

---

## 4. Window detection & accumulation (`UsageCalculator.calculate`)

Constants: `windowDuration = 5h`, `weekDuration = 7d`, `activityCutoff = 300s`.

### 4.1 Preprocessing
- Keep only `message.role == "assistant"` entries **with** a `usage` object and a
  timestamp.
- **Dedup by `requestId`** (Claude Code writes the same response multiple times on
  streaming reconnects) — keep earliest per id.
- Sort ascending by timestamp.

### 4.2 5-hour window start (rolling)
Walk entries; start at the first entry, and **advance the window start** to any
entry that falls more than 5h after the current start:
```
windowStart = all[0].ts
for ts in all[1...]:
    if ts > windowStart + 5h: windowStart = ts
windowEnd = windowStart + 5h
```
This finds the current active 5h block. If `windowEnd <= now`, the window is
expired → return a fresh empty session (weekly figures still populated).

### 4.3 7-day window start
Same rolling algorithm, but lookback is **capped at ~10 days** (`tenDaysAgo`) so
it can find one full 7-day boundary without walking months of history. Falls back
to all entries if nothing in the last 10 days.

### 4.4 Accumulation (within `[windowStart, now]`)
Per qualifying entry, using that entry's model rates:
- `creditsUsed += ceil(input×in_rate + output×out_rate)`
- `inferenceTokens += input + output`
- `cacheCreation += cache5mWrite + cache1hWrite`
- `cacheRead += cache_read_input_tokens`
- `totalCost += cost(model)` (see §5)
- `isActive = true` if any entry within last `300s`

Weekly accumulation is the same but over `[weeklyWindowStart, now]` (credits +
cost only).

Percentages:
```
percentUsed        = min(creditsUsed        / creditCap,       1.0)   // local, CC-only
weeklyPercentUsed  = min(weeklyCreditsTotal / weeklyCreditCap, 1.0)
```
`cliPercentUsed` is stored = `percentUsed` (the pre-API, local-only figure), so
the local number survives after the API overlay replaces `percentUsed`.

---

## 5. Cost model (USD, `ModelPricing`) — informational

Independent of credits; mirrors Anthropic public **API** pricing (USD/1M tokens,
divided to per-token). Used for the "$" figures, not the limit %.

| Model | input | output | cache 5m write | cache 1h write | cache read |
|---|---|---|---|---|---|
| fable-5 / mythos-5 | 10 | 50 | 12.50 | 20.0 | 1.00 |
| opus-4.6/4.7/4.8 | 5 | 25 | 6.25 | 10.0 | 0.50 |
| sonnet-4.5/4.6 | 3 | 15 | 3.75 | 6.0 | 0.30 |
| haiku-4.5 | 1 | 5 | 1.25 | 2.0 | 0.10 |
| fallback (unknown) | 3 | 15 | 3.75 | 6.0 | 0.30 (sonnet) |

Cache-write rate multipliers: **5m TTL = 1.25×** input, **1h TTL = 2.0×** input.
Matching: exact key, then bidirectional prefix, then sonnet fallback.

```
cost = input×in + output×out + cache5mWrite×cw5m + cache1hWrite×cw1h + cacheRead×cr
```
Cache-token accessors (`TokenUsage`): prefer the TTL-split `cache_creation` object
(`ephemeral_5m/1h_input_tokens`); fall back to the flat
`cache_creation_input_tokens` (counted as 5m) when the split is absent (older logs).

---

## 6. Merging API over local (`applyingAPIUsage` + `UsageEngine.refresh`)

Refresh order (`UsageEngine.refresh`, on a detached utility task):
1. `apiClient.fetchUsage()` **first** — so `detectedPlan` is set before caps pick.
2. `cap`/`weeklyCap` from `detectedPlan` (or Pro default).
3. Load JSONL, `calculator.calculate(...)` → local `WindowUsage`.
4. If API data present, `result = result.applyingAPIUsage(apiData)`.
5. Record a calibration sample (§7).
6. Publish `detectedPlan`, `authMode`, `usage` on the main actor.

`applyingAPIUsage` overlays **only the authoritative fields**, keeping the
JSONL-derived token/cost breakdown:
- `percentUsed`      ← `min(fiveHour.utilization/100, 1.0)` (else keep local)
- `windowEnd`, `secondsUntilReset` ← from `fiveHour.resets_at` (else keep local)
- `weeklyPercentUsed` ← `min(sevenDay.utilization/100, 1.0)` (else keep local)
- `weeklyWindowEnd`  ← `sevenDay.resets_at` (else keep local)
- `hasAPIData = true`

Per-window fallback is independent: a response with `five_hour` but no `seven_day`
overlays only the 5h field and leaves weekly on the local estimate.

### All-surfaces "credits" figure (`WindowUsage.displayCredits`)
So the displayed credit count shares the headline's basis:
```
displayCredits = (hasAPIData && creditCap > 0) ? percentUsed × creditCap : creditsUsed
```
i.e. back-solved from the authoritative % when the API is live, else the local
CC-only count.

### Breakdown rows (residual math, `UsageMetricsView`)
The panel decomposes the headline into two rows, both as **percentages**:
- **Claude Code (this machine):** `cliPercentUsed` (local, CC-only).
- **Other devices & web:** `max(0, percentUsed − cliPercentUsed)` — a **residual**,
  not a measured value. Labeled `~estimated` when `hasAPIData`, and shown
  **unavailable** when `!hasAPIData` (no API ⇒ no cross-surface total to subtract
  from). Because `percentUsed` is all-surfaces and `cliPercentUsed` is CC-only,
  the residual absorbs other machines' CC + web + mobile, and is clamped ≥ 0
  (local can exceed the API % due to the cache-exclusion mismatch in §7).

---

## 7. Accuracy & calibration

### What's authoritative vs estimated
| Figure | Basis | Accuracy |
|---|---|---|
| 5h/7d **%** (API present) | Anthropic `utilization` | **Authoritative, all-surfaces** |
| Reset countdowns (API present) | Anthropic `resets_at` | Authoritative |
| 5h/7d **%** (API absent) | local `credits ÷ cap` | Estimate, **CC-only**, cache-exclusive |
| `displayCredits` (API present) | `% × cap` | Only as good as the (unofficial) cap |
| USD cost | local tokens × public API pricing | Estimate; **API pricing ≠ subscription value** |
| `cacheCreation`/`cacheRead` tokens | local JSONL | Exact (this machine's CC) |

### Calibration logging (`CalibrationLogger`)
On every refresh **with** API data, appends one JSONL sample to
`~/Library/Application Support/ClaudePulse/calibration.jsonl`. Serialized on a
private queue, de-duplicated by signature `windowStart|apiPct|credits|cacheCreate`
so idle 60s ticks don't bloat the file. Skips samples where
`apiUtilizationPct < 0` (no API).

`CalibrationSample` fields: `timestamp, windowStart, hasAPIData,
apiUtilizationPct (0–100), cliCredits (CC-only, cache-exclusive),
cacheCreationTokens, cacheReadTokens, inputOutputTokens, creditCap, plan`.

**Intent (fitter NOT yet built):**
1. Fit the real cap: `cap ≈ Σ(local credits) / (api utilization fraction)` on
   windows where local CC is the *only* surface active.
2. Regress residuals against `cacheCreationTokens` to decide whether a
   **cache-creation term** belongs in the credit formula. The strong hypothesis
   is yes — cache reads are free but cache *creation* likely consumes quota,
   which is why local % can read ~0% while real usage is non-trivial.

Calibration only accumulates on **subscription machines**. The primary dev
machine is API-key auth, so its log stays empty (expected).

---

## 8. Known limitations (inherent, not bugs)

- **Fallback scope-shift.** No API 5h window ⇒ headline silently becomes a local,
  CC-only, cache-exclusive `credits ÷ cap` estimate — different scope/basis under
  the same label.
- **No per-surface itemization.** API returns one aggregate %. "Other devices &
  web" is a **residual** (`total − local CC`), lumping other machines' CC + web +
  mobile. Only *this* machine's CC is separable.
- **Cache-creation excluded from credits** though it probably counts toward the
  real limit (§7).
- **Unofficial caps.** 550K/3.3M/11M etc. are community-sourced, not from
  Anthropic; the calibration mechanism exists to correct them.
- **Cost ≠ subscription value.** USD figures use public API pricing; on a
  subscription those messages aren't billed per-token.
- **API-key / credit mode:** no 5h/weekly window exists; no balance endpoint
  exists (spend only); Admin API needs an **org** account.
- **Rate limits (RPM/TPM/TPD):** configured ceilings readable via Rate Limits API;
  live per-minute usage only in Messages API response headers the app never sees.
- **Dev-machine note.** Primary dev machine = API-key auth → `hasAPIData` always
  false, subscription panel runs pure local fallback, `calibration.jsonl` empty.
  Validate the OAuth path on a subscription machine.

---

## 9. Derived UI signals: state, colors, notifications

### `UsageState` (`Models/UsageState.swift`) — thresholds
`UsageState.from(percent, isActive)`:
- `!isActive` → **idle** (no activity in last 300s).
- `percent < 0.70` → **healthy** · `< 0.90` → **warning** · else → **critical**.
- `resetting` exists as a state but isn't produced by `from(...)` — it's a
  display-only state (menu bar `↺`, widget blue).

Drives: menu-bar color/label (`MenuBarIcon`, `menuBarLabel`: idle `—`, critical
`!`, healthy/warning append the %), progress-bar gradient, `guidanceText`, and
notification thresholds. The **weekly** row derives its own state via
`UsageState.from(weeklyPercentUsed, weeklyPercentUsed > 0)`.

### Notifications (`Notifications/NotificationManager.swift`)
Threshold-based, on `usage.percentUsed` (the all-surfaces % when API present),
gated by the user's `notificationsEnabled` toggle:
- **warning** at ≥ 0.70, **critical** at ≥ 0.90 — each fires **once per window**,
  tracked in `firedThresholds`. Crossing critical removes `warning` so it re-arms
  next window.
- **Reset detection:** prior `percent > 0.10` then `< 0.05` with something already
  fired ⇒ clear `firedThresholds`, emit a "Window Reset" notice.
- Auth requested lazily (`.alert`,`.sound`) only when status is `notDetermined`.

---

## 10. Widget target (`ClaudePulseWidget/`) — divergent calc path

The macOS widget is a **separate target** that recomputes usage independently and
**does NOT share the API overlay or plan detection**:
- Reads JSONL directly from `~/.claude/projects` (its own copies of
  `loadAllEntries`/`jsonlFiles`, mirroring `UsageEngine`) and calls
  `UsageCalculator.calculate(...)`.
- **Always uses Pro caps** (`creditCapPro`/`weeklyCreditCapPro`) and shows
  `usage.percentUsed` — which, with no API overlay, is the **local, CC-only,
  cache-exclusive, Pro-capped estimate**. So on Max plans (or any multi-surface
  usage) the widget under-reports vs. the menu bar. ⚠️ A rebuild should either
  share plan/API state with the widget (App Group) or document this divergence
  (see [REBUILD.md §5](REBUILD.md), item B/parity).
- Timeline: one entry/minute up to `windowEnd` (capped 6h), refresh policy
  `.after(windowEnd)`. Renders a ring (`trim: 0…percent`), % and reset countdown.
- `RateLimitWindow`/`APIUsageData` live in `UsageCalculator.swift` specifically so
  the widget target can compile against the shared calc types.

---

## 11. Code map

| Concern | File / symbol |
|---|---|
| JSONL parse, model pricing, cache-token accessors, `cost()` | `ClaudePulse/Core/JSONLParser.swift` |
| Credit rates, caps, window detection, accumulation, `WindowUsage`, `applyingAPIUsage`, `displayCredits` | `ClaudePulse/Core/UsageCalculator.swift` |
| OAuth fetch, Keychain read, `AuthMode`/plan detection, response parse | `ClaudePulse/Core/UsageAPIClient.swift` |
| Refresh orchestration, file watching, `CalibrationLogger`/`CalibrationSample` | `ClaudePulse/Core/UsageEngine.swift` |
| `ClaudePlan`, caps mapping, settings | `ClaudePulse/Settings/SettingsStore.swift` |
| Menu-bar panel (5h block, residual breakdown, weekly) | `ClaudePulse/UI/UsageMetricsView.swift`, `PopoverView.swift` |
| State thresholds, colors, guidance text | `ClaudePulse/Models/UsageState.swift` |
| Menu-bar icon/label rendering | `ClaudePulse/UI/MenuBarIcon.swift` |
| Threshold + reset notifications | `ClaudePulse/Notifications/NotificationManager.swift` |
| Widget (separate target, local-only calc) | `ClaudePulseWidget/ClaudePulseWidget.swift` |

---

For the forward-looking rebuild spec (combined subscription + API UI, generalized
spend, Admin Usage & Cost API, engine contract, and the rebuild checklist), see
**[REBUILD.md](REBUILD.md)**.
