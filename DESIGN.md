# Claude Pulse — Design

A native macOS menu-bar utility for monitoring Claude usage limits at a glance.
This document records the *why* behind the design so future changes have context —
the goals, the data model, the decisions we made and their rationale, and the
limitations that are inherent rather than bugs.

> Scope note: this is a committed design doc. It must never contain secrets
> (API keys, OAuth tokens, credential values).

---

## 1. Goals

- **Glanceable limit proximity.** Answer "how close am I to being throttled / how
  much have I spent?" from the menu bar, without opening a terminal or dashboard.
- **Calm, minimal UI.** Low-distraction, native, lightweight. Built for heavy
  Claude Code users.
- **Honest numbers.** Prefer showing "unavailable" over a misleading figure. Where
  a value is an estimate or a residual, it should read as one.

The app tracks the constraints Anthropic actually enforces, which fall into **two
disjoint systems**:

1. **Subscription (Pro / Max)** — a 5-hour rolling window and a 7-day window,
   shared across *all* subscription surfaces (claude.ai web, desktop, mobile,
   Claude Code logged in via subscription).
2. **API / prepaid credits** — pay-per-use billing with per-minute rate limits
   (RPM/TPM/TPD) and a prepaid credit balance. **No 5-hour or weekly window.**

These two systems do **not** share a pool. A given Claude Code install
authenticates one way at a time, which drives the "two modes" design in §4.

---

## 2. Data sources

| Source | What it gives | Scope | Where |
|---|---|---|---|
| **Local JSONL** (`~/.claude/projects/**/*.jsonl`) | token counts, estimated cost (USD), activity detection, model mix | **This machine's Claude Code only** | `JSONLParser`, `UsageCalculator` |
| **claude.ai OAuth usage endpoint** (`/api/oauth/usage`) | authoritative subscription `utilization` % + reset times for the 5-hour and 7-day windows | **All subscription surfaces** | `UsageAPIClient` |
| **Anthropic Admin / Console Usage & Cost API** *(future)* | org-wide token usage + USD spend | **Whole org, all machines** | not yet built |

Key properties:

- The OAuth endpoint returns a **single aggregate `utilization` percentage** per
  window — Anthropic does **not** itemize by surface. Any per-surface breakdown the
  app shows is therefore one *measured* slice (local Claude Code) plus a
  *residual*, never a true itemized sum.
- The OAuth token the app uses comes **only** from Claude Code's own subscription
  login (an OAuth-JSON Keychain item). The Claude desktop app's session (encrypted
  "Claude Safe Storage") and browser cookies are **not** usable by the app.
- The Admin API reports **spend and usage history**, not a live **credit balance**,
  and requires an **organization** account (not individual) with an
  `sk-ant-admin01-…` key.

### Credentials (Keychain)

`UsageAPIClient` reads the Claude Code OAuth credential from the login Keychain,
trying these generic-password service names in order:

1. `Claude Code` (current, Claude Code 2.x)
2. `claude.ai` (proxy transport)
3. `Claude Code-credentials` (legacy)

It matches by **service only** (account = system username is not hardcoded) and
accepts **only OAuth-JSON** payloads (`{claudeAiOauth:{accessToken…}}`). It
deliberately **rejects a plaintext `sk-ant-…` API key** — the `Claude Code` service
can also hold an API key for API-key auth, and that must never be sent as a bearer
token to the OAuth usage endpoint.

---

## 3. The credit / cap model

The subscription limit is modeled locally as "credits":

```
credits = ceil(input_tokens × input_rate + output_tokens × output_rate)
```

- Per-model rates (`CreditRates`) and the per-plan caps come from
  `she-llac.com/claude-limits` — session caps 550K (Pro) / 3.3M (Max5) / 11M
  (Max20); weekly caps 5M / 41.67M / 83.33M.
- **Cache tokens are excluded by design** ("cache reads = 0 credits (free on
  subscription plans)").

This local model is used for:
- the **fallback** headline % when the API is unavailable, and
- the **Claude Code sub-slice** in the breakdown (which the API can't provide,
  since it doesn't break usage out by surface).

---

## 4. Display model — two mutually-exclusive modes

Which credential Claude Code has determines what the panel can honestly show.

### Subscription mode (OAuth-JSON credential present)
- **5-hour window** and **7-day window** as % of the subscription limit
  (API-authoritative, all surfaces) with reset countdowns.
- Breakdown decomposes the headline into **Claude Code (this machine, measured)**
  and **Other devices & web (residual = total − local)**.
- This is the current implemented panel.

### API-key mode (`sk-ant-…` credential)
- **No subscription window** — the 5-hour/weekly framing does not apply.
- Show **spend / tokens** instead:
  - **now:** estimated USD spend from local JSONL (this machine), and/or
  - **with an Admin key** (entered in Settings): real org-wide spend/usage via the
    Console Usage & Cost API.
- *Not yet implemented* — see §7.

### Current UI (5-hour block)
- Big % + credits ("used") + reset countdown, with a progress bar.
- Below it: **Claude Code** and **Other devices & web** rows. The old "Total" row
  was removed (see §5) — the headline % *is* the total.
- The "This week" block shows the 7-day window.

---

## 5. Design decisions (and why)

- **Headline % is all-surfaces, API-authoritative.** `percentUsed` is overwritten
  by the OAuth `utilization` when available; the app is framed around subscription
  *limit proximity*, and the authoritative cross-surface number is the honest
  answer. (`applyingAPIUsage` in `UsageCalculator`.)
- **"used" credits figure is all-surfaces too** (`displayCredits`): back-solved as
  `percentUsed × creditCap` when API data is present, so the number shares the
  headline's basis instead of pairing an all-surface % with a CC-only credit count.
- **Removed the "Total" row.** The headline % and bar already are the all-surfaces
  total; a "Total" breakdown row restated the same value and drew a duplicate bar.
  The two remaining rows read as a decomposition of the headline.
- **Always render the source-row track bar**, even when a source is unavailable, so
  rows keep consistent height.
- **Dropped "tokens remaining."** For subscription it's only an estimate (the API
  returns a %, not tokens, and the token-cap is unofficial); for API it isn't a
  native quantity. Showing only authoritative fields is more honest.
- **Two mutually-exclusive modes, not two simultaneous bars.** The two limit
  systems are disjoint and a machine is usually authenticated to one. The mode is
  driven by the credential type.
- **Keychain: multi-name lookup, OAuth-JSON only.** Current Claude Code renamed the
  service; accepting a plaintext API key as a bearer token would be both wrong and
  a credential-misuse risk.
- **Calibration logging.** The app receives both the authoritative % and its own
  local credit estimate on every refresh but historically discarded the
  comparison. `CalibrationLogger` now persists paired
  `(api utilization, local CC credits, cache-creation, cache-read, cap)` samples so
  the caps can later be fit against reality (see §7).

---

## 6. Known limitations

These are inherent to the available data, not defects:

- **Fallback scope-shift.** When the OAuth endpoint returns no five-hour window
  (API unavailable *or* a response missing `five_hour`), the headline % silently
  falls back to a **local, Claude-Code-only, cache-exclusive** `credits ÷ cap`
  estimate — a different scope and basis under the same label.
- **No per-surface itemization.** Anthropic exposes one aggregate number per
  window. "Other devices & web" is a **residual** (total − local Claude Code), not
  a measured value; it also lumps in other machines' Claude Code and mobile.
- **Only this machine's Claude Code is separable.**
- **Cache-creation likely counts toward the real limit but credits exclude it.**
  The credit model is cache-exclusive; cache *reads* are genuinely free, but cache
  *creation* probably consumes quota. This is why the local % can read ~0% while
  real cost is non-trivial, and why calibration logging exists.
- **API-key / credit users:**
  - The 5-hour/weekly framing does not apply at all.
  - **Prepaid credit balance is not obtainable via API** — the Admin API reports
    spend, not remaining balance. Balance is Console-UI-only.
  - The Admin API **requires an organization** account, not an individual one.
  - Cross-machine API usage needs the Admin/Console integration.
- **Rate limits (RPM/TPM/TPD).** Configured ceilings are readable via the separate
  Rate Limits API, but live per-minute usage is only in Messages API response
  headers the app never sees — and per-minute isn't glanceable anyway.
- **Dev-machine note.** The primary dev machine authenticates Claude Code with an
  API key (prepaid credits), so `hasAPIData` is false there and the subscription
  panel runs entirely in its local-estimate fallback. This is expected, not a bug —
  validate the subscription/OAuth path on a subscription machine.

---

## 7. Future work

- **Implement the two modes** — detect credential type (OAuth-JSON vs `sk-ant`) and
  render the matching panel; replace the meaningless "% of 5-hour window" that
  API-key usage currently shows with a spend meter.
- **Cap recalibration / fitter.** Consume the calibration samples: fit
  `cap = Σ(local credits) / (api utilization fraction)` on Claude-Code-only
  windows, and use residuals vs cache-creation volume to decide whether a
  cache-creation term belongs in the credit formula.
- **Console / Admin API integration.** Optional `sk-ant-admin01-…` key in Settings
  → real org-wide spend/usage (Usage & Cost API); fall back to the local estimate
  when absent. Surface the "requires an organization account" constraint in the UI.
- **Spend-vs-budget.** Since real balance isn't available, optionally let the user
  enter a starting/purchased balance or budget and show spend against it.

---

## 8. Code map

| Area | File |
|---|---|
| JSONL parsing, model pricing, cache-token accessors | `ClaudePulse/Core/JSONLParser.swift` |
| Window/credit calculation, caps, `WindowUsage`, `applyingAPIUsage`, `displayCredits` | `ClaudePulse/Core/UsageCalculator.swift` |
| OAuth usage fetch, Keychain credential read, plan detection | `ClaudePulse/Core/UsageAPIClient.swift` |
| Refresh orchestration, calibration logging | `ClaudePulse/Core/UsageEngine.swift` |
| Menu-bar panel (5-hour block, breakdown, weekly) | `ClaudePulse/UI/UsageMetricsView.swift` |
