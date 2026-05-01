# ClaudeMeter — Architecture & Decisions

Quick reference for AI assistants continuing work on this project.

## Release History

### v2.4

- **Plan tier in section header**: the first section title now reads `PLAN USAGE LIMITS - MAX 20X` (or `- PRO`, `- TEAM`, `- ENTERPRISE`, etc.). The slug is read from `rate_limit_tier` on the `/api/organizations` response (top-level on each org, not nested under `settings`), mapped to a friendly display name, and persisted in UserDefaults. Unknown future tiers fall back to a titlecased stem.
- **Proactive plan-tier fetch**: a new `refreshPlanTierIfNeeded` runs ~4s after launch and is independent of the usage JSON path, so the chip populates even when the JSON circuit breaker is open.
- **Combined countdown row**: the static "Resets ..." detail and the live countdown are collapsed into one row, e.g. `Resets Tue 11:00 PM, in 4d 9h` or `Resets Jun 1, in 30d 10h`. The "Resets ..." prefix is synthesized from the parsed `resetAt` and scales by horizon (time-only within 24h, weekday+time within a week, month+day beyond).
- **Headline hidden until predictable**: "gathering data..." no longer renders on fresh launch; the ETA headline only appears once a forecast has a real ETA, so the popover does not look like it is glitching while history accrues.
- **Reset parser improvements**: `parseClaudeReset` now combines hours and minutes when both appear ("Resets in 4 hr 11 min" anchors at 4h11m, not 4h flat) and handles month+day forms ("Jun 1", "January 5") used by billing-style resets.
- **Estimator scoped to known cadences**: `applyResetEstimates` only applies the 5h/7d firstSeen fallback to "Current session" and "Weekly" meters. Other meters (Extra usage, All models, Sonnet only) keep their countdown row hidden when the detail string cannot be parsed, avoiding wrong short-horizon countdowns.
- **Long-duration formatting**: countdowns longer than 24 hours render as `Nd Mh` instead of `105h 31m`.
- **Popover height**: the resize ceiling is now `max(1200, screen.visibleFrame.height - 40)` so taller content fits, with deferred re-measurements (initial, post-layout, post-animation) to work around `fittingSize` under-reporting before the scrollView's real width has settled. The popover also auto-scrolls to the top on every open and re-snaps after each fresh data render.
- **JSON empty falls through to DOM**: when the JSON path returns zero meters (shape mismatch or auth-soft-fail), the coordinator now invokes the DOM scrape instead of feeding the empty result into the empty-streak gate. Counts toward the same circuit breaker as JSON errors.
- **Cookie copy fix**: `copyCookiesToSession` was previously using `sharedCookieStorage(forGroupContainerIdentifier:)`, which silently fails without an app-group entitlement. It now uses the ephemeral session's own in-memory storage and explicitly seeds it from the WKWebView cookie store, so JSON requests actually carry auth.
- **Internal**: new diagnostic logs (`copyCookiesToSession: attached N cookies`, `discoverOrgUUID got N orgs`, `plan tier resolved: <slug>`) make field issues with the JSON path traceable from stderr alone.

### v2.3

- **Live reset countdown**: each meter now shows a small "resets in 2h 14m" line directly under its detail row, updated once per second while the popover is open. Format adapts to remaining time: `Xh Ym` (over an hour), `Xm` (under an hour), `Xs` in amber (under 10 min), and `resetting...` in amber (under a minute). Hidden entirely when no `resetAt` is available, and hidden again after the reset fires until the next scrape supplies a fresh value.
- **Peak-hour flame indicator**: a small flame icon appears next to the "Current session" meter label when the local clock falls inside Anthropic's peak-hour window (Mon-Fri, 5 to 11 AM Pacific). The icon's tooltip shows how much of the window is left and is refreshed every second so the remaining time stays current.
- **Peak window definition:** Mon-Fri 5 to 11 AM Pacific. Stored as a single `peakWindow` constant near the top of `AppDelegate`; update there if Anthropic shifts it. DST is handled automatically because the check uses `TimeZone(identifier: "America/Los_Angeles")`.
- **`UsageMeter.resetAt`**: the data model now carries a parsed reset `Date?` per meter. The JSON path populates it directly from the `resets_at` field (ISO-8601, with a fall-through to the v2.1 string parser); the DOM path parses from `meter.detail` first, then falls back to a persisted "first seen" anchor in UserDefaults plus a 5h (session) or 7d (weekly) window. The first DOM scrape after launch with no anchor stores `Date()` and tags the countdown with a leading `~` to signal an estimate.
- **Battery-respecting ticker**: a single 1Hz `Timer` lives inside `UsageContentView` and is started from `togglePopover` and stopped from `popoverDidClose`, so the ticker is dormant whenever the popover is hidden. Tolerance `0.2`, common run-loop mode. The unified refresh timer is unchanged; no third refresh path was added.
- **Internal**: new L1 static-audit checks enforce a single `peakWindow` struct definition and a `popoverDidClose` that stops the countdown ticker (battery regression guard).

### v2.2

- **Threshold notifications**: macOS user notifications fire when session or weekly usage crosses 50%, 75%, or 90%. Notifications are time-sensitive (so Focus modes won't suppress them by default), include a "Snooze rest of cycle" action, and are off by default to respect user privacy. Authorization is requested lazily on the first fire, never on launch.
- **Per-threshold mute toggles**: a new "Notifications" submenu in the right-click menu exposes a master enable toggle plus six per-threshold checkboxes (Session 50/75/90%, Weekly 50/75/90%) so users can opt out of any subset without disabling notifications globally.
- **Idempotent, anti-flap fire logic**: each `(scope, threshold, cycleKey)` tuple fires at most once per cycle. The "fired" flag is set BEFORE the notification is dispatched, so concurrent scrape evaluations can't double-fire, and percentage drops back below a threshold do not re-arm it (only a new cycle does).
- **Cycle-boundary detection**: cycle keys are derived from the parsed reset timestamp (via the v2.1 `Date.parseClaudeReset` helper) when available; an in-defaults rolling anchor (5h session, 7d weekly) is used when the detail string is missing or unparseable.
- **Snooze action**: tapping "Snooze rest of cycle" on any notification suppresses all further thresholds for that scope until the next cycle; once the cycle key changes, snooze and fired flags effectively reset.
- **Single evaluation seam**: notifier evaluation runs exactly once per successful scrape, gated by the same `distributeFetchResult` funnel that owns history append and view update. No additional timers; no risk of rogue evaluations.
- **Internal**: stale `notif.fired.*`, `notif.snoozed.*`, and `notif.lastPct.*` UserDefaults keys are pruned on init when their embedded cycle timestamp is older than 14 days, keeping the plist bounded.
- **Internal**: new L1 static-audit checks enforce no consent-on-launch regression, a single evaluation callsite, paired idempotency guards on every `notif.fired.*` write, presence of `interruptionLevel = .timeSensitive`, and no `NSUserNotification` (deprecated) usage.

### v2.1

- **Burn-rate + ETA-to-limit headline**: the popover now leads with two big-text rows ("out at 3:42p" for the session, "hits weekly cap Wed 9a" for the weekly cap), with the raw % demoted to a small secondary number on the right. The ETA timestamp turns red when the projected exhaustion lands before the next reset, white otherwise. Per-meter percentages in the section list stay untouched.
- **EWMA burn-rate model**: rate is computed as an exponentially weighted moving average (alpha = 0.3) over inter-sample slopes (% per hour). Session forecast looks at the last 30 min of samples; weekly forecast uses the full 24h retention window. ETA is `now + (100 - currentPct) / rate`, clamped to the next reset.
- **Sample history with disk persistence**: every successful scrape appends a `(timestamp, sessionPct, weeklyPct)` sample to a 24h ring buffer, persisted (throttled to once per 30s) to `~/Library/Application Support/ClaudeMeter/history.json`. This is the first on-disk file the app writes; the directory is created lazily.
- **Reset-time parsing**: a new `Date.parseClaudeReset(_:)` helper converts strings like "Resets at 3:42pm", "Resets Wed 9am", and "Resets in 2h" into absolute Date values. Falls back to `now + 5h` (session) or next Monday 00:00 local (weekly) when the string is missing or unparseable.
- **Noise-floor states**: the headline shows "gathering data..." until at least 3 samples spanning the minimum window land; "no recent activity" when the smoothed rate is at or below 0.05 %/hr; and "won't hit weekly cap" / "session won't hit limit" when the projected ETA lands past the reset.
- **Skeleton parity**: the loading skeleton now includes two shimmer rows above the section list so the v1.5 fade-in stays aligned with the new headline.

### v2.0

- **JSON-primary fetch path with DOM-scrape fallback**: usage data now comes from the undocumented `/api/organizations/{uuid}/usage` endpoint when available, falling back to the existing DOM scrape when JSON is disabled, errored, or its in-memory circuit breaker has tripped. Both paths funnel through a single distribution gate so popover, badge, empty-streak detection, and telemetry are unchanged from the consumer's perspective.
- **Lazy org UUID discovery**: first JSON attempt with no cached UUID hits `/api/organizations`, prefers an org whose capabilities include `claude_pro`/`claude_max`, and caches the result in UserDefaults. 401/403/404 from the usage endpoint invalidates the cache so the next attempt rediscovers.
- **Cookie bridging**: per-call URLSession is built from a snapshot of all WKWebView cookies, so the JSON request rides the same authenticated session as the page itself.
- **Rollback switch**: `defaults write com.local.ClaudeMeter forceDOMOnly -bool YES` skips the JSON path entirely. No restart needed.
- **Soft circuit breaker**: 5 consecutive JSON failures silently degrade to DOM-only for the session; reset on relaunch.
- **Centralized fetch telemetry**: every fetch logs `[ClaudeMeter] fetch path=json|dom outcome=success|empty|error detail=...` via `logFetchOutcome`, mirroring the `setBadgeTitle` convention so the QA pipeline can verify path/outcome transitions from stderr alone.
- **Internal**: new L2.5 QA layer validates `UsageAPIResponse` normalization against a sample API response, in addition to the existing DOM-contract check.

### v1.9

- **Fixed badge stuck at stale value** (regression from v1.8): the menu bar percentage now updates reliably even when the page's structured scrape can't produce a clean "Current session" label, by falling back to a dedicated XPath scrape
- **Deterministic label detection**: the structured scrape now prefers leaf text matching `Current session`, `Weekly`, `Opus`, `Sonnet`, or `Haiku` before falling back to the first short text node, so meter labels no longer depend on DOM order
- **Robust against transient empty scrapes**: popover and badge no longer flicker to `—%` during normal React re-renders; an empty result must repeat 3 times in a row before being treated as a real failure
- **Centralized badge title updates**: every status-item title write now routes through a single helper that logs the old and new value with a reason string, making field issues much easier to diagnose
- **Internal:** new `qa/` directory with smoke tests, drift checks, and static-audit scripts to catch DOM-scraper regressions before release

### v1.8

- **Unified data store and refresh timer**: badge and popover now share a single source of truth for usage data and a single background refresh timer, instead of running independent fetch paths

### v1.7

- **Fixed popover flickering** during refreshes
- **Update checking**: built-in "Check for Updates..." menu item with code-signature verification
- **Refined UI**: visual polish across popover, badge, and menu

### v1.6

- **Instant badge on launch** — cached last-known usage percentage displays immediately in the menu bar, updated with fresh data once the page loads
- **Delayed post-load scrape** — second scrape 2s after page load ensures React has rendered before updating badge and popover
- **Fixed skeleton layout constraints** — shimmer placeholder name bars use flexible widths to avoid Auto Layout warnings

### v1.5

- **Shimmer skeleton loading** — popover opens with an animated skeleton placeholder that matches the real layout, instead of a blank window
- **Minimum skeleton display** — skeleton holds for at least 0.6s so the animation is visible even on fast loads
- **Smooth content transition** — real data crossfades in with an animated popover height adjustment
- **Skeleton on every open** — loading animation shows each time the popover opens, not just on first launch

### v1.4

- **Tighter popover layout** — reduced vertical spacing throughout (edge insets, section dividers, meter gaps) to eliminate excess whitespace
- **Dynamic popover sizing** — popover height now auto-sizes to fit content instead of using a fixed 380px height
- **Dynamic Safari UA** — user agent string now derives Safari version from the host macOS version instead of being hardcoded

### v1.3

- **Badge Refresh Interval submenu** — configurable background polling for menu bar badge (30s / 1m / 2m / 5m / 10m), default 2 minutes
- **Background badge updates** — badge auto-updates in background even when popover is closed
- **Battery efficiency** — improved timer tolerance for better energy impact
- **Code signature verification** — auto-updates now verify code signatures before applying
- Various robustness and stability improvements

### v1.2

- **Auto-polling** — configurable refresh interval (6s / 20s / 30s / 60s) keeps data fresh while popover is open
- **Status dot states** — grey (stale), yellow/believed-fresh (recently updated, verifying), green (confirmed fresh)
- **Loading spinner** — tiny spinning ring around the status dot during active fetches
- **Menu bar badge** — "Show Usage in Menu Bar" toggle displays current session usage percentage next to the icon
- **Refresh Interval submenu** — right-click context menu to pick polling frequency; persisted via UserDefaults
- **NSPopoverDelegate** — polling stops automatically when popover closes

### v1.1

- Self-update system and move-to-Applications prompt
- CI release workflow

### v1.0

- Initial release: cookie import, usage display, soft reload, status dot

## Architecture

**Single file:** `ClaudeMeter.swift` — entire app, no dependencies beyond system frameworks.

### Auth — Claude Desktop cookie import (primary)

- **Proactive import at startup:** always imports cookies before loading the page (not just on login redirect)
- Reads Claude Desktop's Chromium SQLite cookie DB at `~/Library/Application Support/Claude/Cookies`
- Decrypts cookies using the "Claude Safe Storage" key from macOS Keychain via PBKDF2 + AES-128-CBC
- Encryption format: `v10` prefix (3 bytes) + IV (16 bytes) + ciphertext; plaintext has a 16-byte internal prefix to skip
- Injects decrypted `HTTPCookie` objects into WKWebView's `.default()` data store
- First run triggers a macOS Keychain permission dialog ("Always Allow" recommended)

### Auth fallback — WKWebView login window

- Full-size NSWindow with WKWebView pointed at `claude.ai/login`
- Works for email/magic-link login (Google OAuth may fail in WKWebView)
- UA spoofed to Safari to reduce Google blocks
- Real popup windows for OAuth (returns WKWebView from `createWebViewWith` instead of nil)

### Display

- Popover (400px wide, auto-height) with CSS injection to hide nav/sidebar/chrome, showing only usage meters
- Hides: site sidebar, header, "Settings" heading, settings nav tabs, "Extra usage" section, "Learn more" links, "Last updated" row, Intercom widget
- MutationObserver re-applies CSS after React re-renders
- Section headings styled as subtle uppercase labels
- Auto-resizes popover to fit content (clamped 120–500px)

### Reload behavior

- **Soft reload** (popover toggle): clicks the site's own refresh button via JS — no page navigation
- **Graceful reload** (menu Reload): fades content to 40% opacity, reloads, fades back in
- **Silent refresh** (polling timer): clicks refresh button without flashing dot grey; used for background polling
- Status dot states: grey (stale) → yellow/believed-fresh (recently updated, verifying) → green (confirmed fresh)
- Loading spinner (CSS `::after` pseudo-element) appears around dot during fetches
- `lastRefreshDate` tracked in Swift to decide between grey vs yellow on popover re-open

### Auto-polling

- `statusFreshnessInterval` (default 6s) controls poll frequency; configurable via context menu
- `Timer.scheduledTimer` fires `silentRefresh()` while popover is open
- Polling starts on popover open, stops on `popoverDidClose` (NSPopoverDelegate)
- JS-side freshness timeout = interval + 3s buffer (safety net if polling stops)

### Menu bar badge

- Scrapes "Current session" percentage from page DOM via XPath (`scrapeSessionPercentageJS`)
- Displayed as `NSStatusItem.button.title` next to the gauge icon
- Uses `monospacedDigitSystemFont` to prevent width jitter
- Updates on every refresh path: `didFinish`, `softReload`, `silentRefresh`
- Toggle persisted via `UserDefaults` (`showMenuBarBadge` key)

### Menu (right-click)

- Reload, Import from Claude Desktop, Sign In..., Refresh Interval (submenu), Show Usage in Menu Bar, Badge Refresh Interval (submenu), Check for Updates..., Quit

## Key Decisions & Findings

| Decision | Reason |
|---|---|
| Import from Claude Desktop, not Safari | WKWebView `.default()` is completely isolated from Safari's cookie store. No API to share them. |
| Chromium v10 AES-128-CBC, not AES-GCM | Tested — GCM fails with `authenticationFailure`. CBC with embedded IV + skip-16 works for all 26 cookies. |
| PBKDF2 password is the UTF-8 string from Keychain | `security -w` outputs it as base64-looking string, but it IS the literal password. Base64-decoding it produces wrong key. |
| Skip first 16 bytes of CBC plaintext | Chromium prepends a 16-byte internal prefix (possibly integrity hash) before the actual cookie value. |
| Copy DB before reading | Claude Desktop may hold a write lock on the Cookies file. Copy to `/tmp` first. |
| Import at startup, not on login redirect | Stale WKWebView cookies can prevent server redirect to `/login`, causing the reactive import to never trigger. Proactive import avoids this. |
| CSS targets structure, not class names | claude.ai uses generic Tailwind classes — no "usage" in class names. CSS must target DOM structure (`main > h1`, `section > div`, etc.) |
| UA spoofing to Safari | Google's OAuth block is server-side UA detection. Spoofing bypasses it. |
| Real popup windows for OAuth | Returning nil from `createWebViewWith` and loading inline breaks OAuth's `window.opener`/`postMessage` flow. |
| ASWebAuthenticationSession rejected | Its cookie store goes to Safari, not WKWebView. No transfer mechanism exists. |
| Silent refresh for polling | Omits grey flash (keeps dot green) during automatic refreshes — only user-initiated reloads show the loading state transition. |
| Yellow "believed-fresh" state | If `lastRefreshDate` is within the freshness interval when popover opens, shows yellow instead of grey since data is likely current. |
| XPath for DOM scraping | Anchors on stable text content ("Current session", "% used") rather than Tailwind class names which change frequently. |
| Freshness timeout = interval + 3s | Buffer accounts for the ~1.5s delay between clicking the refresh button and data arriving. |
| `variableLength` status item | Switched from `squareLength` to support showing percentage text alongside the gauge icon. `monospacedDigitSystemFont` prevents layout jitter. |
| Badge keeps an independent XPath fallback even after the v1.8 unification | The structured scrape's label-detection can pick an unrelated short text from the card (tooltip, plan name) and miss the "current session" meter entirely. Without a fallback the badge gets stuck at a stale value with no recovery path. The dedicated `scrapeSessionPercentageJS` anchors on literal "Current session" text near a "% used" sibling, so the badge updates whenever either path succeeds. |
| Empty scrapes are counter-gated, not acted on immediately | Logs show transient empty scrapes (0 sections) alternating with real scrapes (2 sections) every 2s during normal React re-renders. Clearing badge/popover on any single empty causes constant `—%` flicker. Three consecutive empties (JS errors count too) is the threshold for a real failure. |
| All badge title writes go through `setBadgeTitle` | Centralizes logging of every change with a reason string, giving the QA pipeline a deterministic signal independent of OCR/screenshots and making field issues diagnosable from logs alone. |
| `NSLog("%@", message)` for any string containing user data | NSLog treats its first argument as a printf format string. The badge contains `%` (e.g. "47%"), which NSLog consumes as a format specifier when inlined, mangling the output. Always pass user-data strings via `%@`. |
