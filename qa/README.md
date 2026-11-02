# ClaudeMeter QA pipeline

A five-layer QA pipeline plus a multi-agent orchestration layer.

The layers are independent shell/JS scripts you can run by hand, in CI, or via
the `/qa` slash command which fans out to specialized Claude subagents in
parallel.

## Why five layers?

Each layer catches a different class of regression. They're ordered cheapest
to most expensive, and each is independently runnable.

| Layer | Script | Catches |
|---|---|---|
| **L0** Build | [build.sh](build.sh) | Swift compile errors; crash-on-launch regressions |
| **L1** Static audit | [static-audit.sh](static-audit.sh) | Missing `[weak self]`, missing scrape fallback, broken timer pairing |
| **L2** DOM contract | [check-selectors.mjs](check-selectors.mjs) | The JS scrapers in `ClaudeMeter.swift` no longer match their fixture DOM |
| **L3** Smoke | [smoke/run.sh](smoke/run.sh) | Badge doesn't render at all (full integration including auth + WKWebView + scrape + status item) |
| **L4** Drift | [drift/watch.sh](drift/watch.sh) | Badge renders but stops updating over time (the v1.8 regression we just fixed) |

## Quick start

```bash
# Run L0–L3 (skips L4, which is long-running):
./qa/qa.sh

# Skip the smoke test (e.g., in CI without screen access):
./qa/qa.sh --fast

# Run a single layer:
./qa/qa.sh --layer L2

# Install the drift watcher as a launchd agent (optional):
cp qa/drift/com.claudemeter.qa.drift.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.claudemeter.qa.drift.plist
```

## Multi-agent orchestration

The pipeline is also exposed as a `/qa` slash command. When you invoke it,
Claude spawns one specialized subagent per layer, **in parallel**, and
aggregates their findings into a single verdict.

```
                  ┌──────────────────────┐
                  │   /qa coordinator    │
                  │  (Claude main loop)  │
                  └──────────┬───────────┘
                             │ fan-out (parallel Agent calls)
   ┌──────────┬──────────────┼──────────────┬──────────────┐
   ▼          ▼              ▼              ▼              ▼
 qa-builder qa-static-    qa-dom-       qa-smoke       qa-drift
            audit         contract                     (audit-only)
   │         │             │              │              │
   └─────────┴─────────────┴──────────────┴──────────────┘
                          │ re-sync
                          ▼
                   Verdict + repro
```

Each subagent is defined under [.claude/agents/qa-*.md](../.claude/agents/) and
reads its instructions there. The coordinator narrows scope on the second pass
(only re-runs layers that flagged something, with extra context) — this is the
"high-syncing" loop the architecture is designed for.

### When to use scripts vs. agents

- **CI / pre-commit**: run the scripts directly via `qa.sh`. No AI cost, fast,
  deterministic.
- **Pre-release / investigations**: invoke `/qa`. The agents add interpretation
  on top of pass/fail (e.g., "L2 failed — here's the diff between expected and
  actual scraper output, here's what likely changed in claude.ai's DOM").
- **The drift watcher (L4)** is always a script. It runs continuously in the
  background; agent overhead doesn't make sense there.

## What each layer does in detail

### L0 Build ([build.sh](build.sh))
Compiles `ClaudeMeter.swift` with `swiftc`, launches the binary, waits 4s, and
verifies the process is still alive. Catches compile errors and crash-on-launch
regressions (e.g., a force-unwrap on a nil cookie).

The binary is launched from a minimal `.app` bundle written next to it
(`$CLAUDEMETER_QA_BIN.app`, bundle ID `com.local.ClaudeMeter.qa`). Since v2.4
the app calls `UNUserNotificationCenter.current()` at launch, which throws
`bundleProxyForCurrentProcess is nil` for an unbundled executable. The distinct
bundle ID keeps QA runs out of the installed app's preferences domain. Both
L0 and L3 pass `-declinedMoveToApplications YES` so a bundled copy outside
`/Applications` never shows the modal "Move to Applications?" alert (which
would block the main thread and, if accepted, copy the QA bundle into
`/Applications`). L3 launches the same bundled copy.

Isolation from the installed app, and what L0 really touches:

- **Preferences:** the QA bundle has its own domain (`com.local.ClaudeMeter.qa`),
  separate from the installed app's `com.local.ClaudeMeter`. Values persist in
  that domain between QA runs; L3 passes `-lastBadgePercentage 0` and
  `-lastBadgePercentage.primary 0` (v2.7.1 key and per-account key) so a cached
  badge from an earlier run cannot be mistaken for a fresh fetch, and the L3
  pass regex ignores `applyBadgeVisibility cached=` transitions for the same
  reason.
- **Application Support:** the app derives its support subfolder from its
  bundle ID. The installed app (and unbundled binaries) keep
  `~/Library/Application Support/ClaudeMeter/`; the QA bundle uses
  `~/Library/Application Support/com.local.ClaudeMeter.qa/`, so QA runs never
  read, migrate or overwrite the real history files.
- **No Keychain access:** every QA launcher (L0, L3, the multi-account test)
  passes `-skipDesktopImport YES -suppressAutoLoginWindow YES`. The app then
  never reads Claude Desktop's cookie database or the "Claude Safe Storage"
  Keychain item. (Each rebuilt QA binary is ad-hoc signed with a new code
  hash, so that read would raise a fresh Keychain prompt on every run, even
  after "Always Allow".) The primary account uses whatever claude.ai session
  the QA bundle's own WebKit store already holds, and when it has none the
  app shows it as signed out instead of opening a login window. Both
  switches default to off; the installed app behaves exactly as before.
  QA never touches any `Claude Code-credentials*` Keychain item.
- **Real side effects:** a QA launch is still a real app run: it makes real
  requests to claude.ai with the QA bundle's own session (if any) and keeps
  cookies in the QA bundle's own WebKit website data store.
- `build.sh` refuses to replace a bundle under `/Applications` or
  `~/Applications`, or one named `ClaudeMeter.app`.

### L1 Static audit ([static-audit.sh](static-audit.sh))
Greps the Swift source for known fragile patterns. Specifically enforces:
- Both `scrapeUsageJS` and `scrapeSessionPercentageJS` exist (defense in depth)
- `updateBadgeFromModel` calls the fallback scraper
- `scrapeAndDistribute` resets the badge on empty result
- `popover.isShown` guard is present in `updateBadgeFromModel` (anti-flicker)
- No stale references to the v1.7 timer API (`startBadgePolling`, `startPolling`)

### L2 DOM contract ([check-selectors.mjs](check-selectors.mjs))
Extracts the JS scrapers from `ClaudeMeter.swift` *at runtime* and runs them
inside jsdom against a fixture HTML. Validates the result against expected
JSON. The synthetic fixture deliberately includes a tricky-label card that
would have failed the v1.7→v1.8 regression we just fixed — this is the
canonical regression test for that bug.

To capture a fresh fixture from the live page, see
[fixtures/README.md](fixtures/README.md).

### L3 Smoke ([smoke/run.sh](smoke/run.sh))
Launches the binary, waits up to 30s for the badge to render a real
percentage, and OCRs the menu bar via Apple's Vision framework
([smoke/ocr.swift](smoke/ocr.swift)). Asserts the OCR'd text contains
`\d+%` (a real percentage), not `—%` (the placeholder). This is the
end-to-end test that would have caught today's "badge stuck" bug
*at the user-visible layer*.

Requires a claude.ai session in the QA bundle's own WebKit store
(`~/Library/WebKit/com.local.ClaudeMeter.qa`), because QA launches skip the
Claude Desktop import (no Keychain prompt) and never auto-open a login window.
Without a session L3 times out with the primary account signed out. One-time
setup, either:

- sign in by hand once (no Keychain access):
  `/tmp/ClaudeMeter.qa.app/Contents/MacOS/ClaudeMeter.qa -declinedMoveToApplications YES -skipDesktopImport YES`
  then right-click the QA menu-bar icon → Sign In…, sign in, and quit; or
- import from Claude Desktop once (one Keychain prompt; choose Allow):
  run the same command without `-skipDesktopImport YES`, wait for the badge,
  and quit.

The session persists across rebuilds because the store belongs to the bundle
ID, not the binary. Won't work in CI without seeded auth.

### L4 Drift ([drift/watch.sh](drift/watch.sh))
Long-running. Samples the badge every 5 minutes (configurable), logs each
observation to JSONL, and posts a system notification if the badge shows the
same value for 12 consecutive samples (i.e., 1 hour without an update). This
is exactly the failure mode that prompted this whole pipeline.

Install as a launchd agent via [drift/com.claudemeter.qa.drift.plist](drift/com.claudemeter.qa.drift.plist).

## Multi-account flow test ([multiaccount/run.sh](multiaccount/run.sh))

Not part of `qa.sh` (about 2 minutes; it briefly opens login windows and the
popover). Builds `ClaudeMeter.swift` together with
[multiaccount/testhooks.swift](multiaccount/testhooks.swift) using
`-D CLAUDEMETER_TESTHOOKS` (release builds never include the hooks), into an
isolated bundle `com.local.ClaudeMeter.qa.multi` with its own prefs domain,
Application Support folder and WebKit stores, and runs two scenarios through
the real code paths:

- **A, accounts:** three seeded accounts (the real primary plus two
  secondaries on empty isolated stores): API-confirmed signed-out detection
  without auto-opened windows, the Accounts menu (including Badge Position
  and Badge Label), staggered timers, rename, add, cancelled add, a requested
  login window, removal (record, exact-ID keys, history file, WebKit store),
  and the orphaned-store sweep.
- **B, badge and popover:** one account (`47%`, popover is the usage view
  itself), two accounts (`P 47% | W --`, `P 47% | W 12%`), slot reassignment
  moving the occupant to Hidden (`W 12%`), right-then-left order, both slots
  hidden (falls back to the primary account), a custom label, a signed-out
  side (`--`), three accounts stacked in the popover with the popover sized
  to their sum, and back to one account.

It cleans up the test domain and folders afterwards (`--keep` leaves them).
Like L0/L3 it skips the Claude Desktop import (no Keychain access); the
primary account here has no session and is shown signed out, and the badge
and popover checks feed it synthetic data.

The L3 smoke regex and the L4 OCR accept all three badge forms: `47%`,
`W 47%` and `P 47% | W 12%` (a side may read `--`).

## Environment variables

| Var | Default | Effect |
|---|---|---|
| `CLAUDEMETER_QA_BIN` | `/tmp/ClaudeMeter.qa` | Where L0/L3 build and launch the binary |
| `CLAUDEMETER_QA_SHOT` | `/tmp/claudemeter.qa.menubar.png` | L3 screenshot path |
| `CLAUDEMETER_QA_TIMEOUT` | `30` | L3 max seconds to wait for badge |
| `CLAUDEMETER_DRIFT_INTERVAL` | `300` | L4 seconds between samples |
| `CLAUDEMETER_DRIFT_WINDOW` | `12` | L4 samples-without-change before alert |
| `CLAUDEMETER_DRIFT_LOG` | `/tmp/claudemeter.drift.jsonl` | L4 sample log |
