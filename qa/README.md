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

Requires Claude Desktop signed in (the app imports cookies from there).
Won't work on a fresh machine or in CI without seeded auth.

### L4 Drift ([drift/watch.sh](drift/watch.sh))
Long-running. Samples the badge every 5 minutes (configurable), logs each
observation to JSONL, and posts a system notification if the badge shows the
same value for 12 consecutive samples (i.e., 1 hour without an update). This
is exactly the failure mode that prompted this whole pipeline.

Install as a launchd agent via [drift/com.claudemeter.qa.drift.plist](drift/com.claudemeter.qa.drift.plist).

## Environment variables

| Var | Default | Effect |
|---|---|---|
| `CLAUDEMETER_QA_BIN` | `/tmp/ClaudeMeter.qa` | Where L0/L3 build and launch the binary |
| `CLAUDEMETER_QA_SHOT` | `/tmp/claudemeter.qa.menubar.png` | L3 screenshot path |
| `CLAUDEMETER_QA_TIMEOUT` | `30` | L3 max seconds to wait for badge |
| `CLAUDEMETER_DRIFT_INTERVAL` | `300` | L4 seconds between samples |
| `CLAUDEMETER_DRIFT_WINDOW` | `12` | L4 samples-without-change before alert |
| `CLAUDEMETER_DRIFT_LOG` | `/tmp/claudemeter.drift.jsonl` | L4 sample log |
