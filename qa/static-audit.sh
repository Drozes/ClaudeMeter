#!/usr/bin/env bash
# L1 — Static audit.
# Greps ClaudeMeter.swift for known fragile patterns. Each finding is reported
# with file:line so editors can jump. Exits 0 if all checks pass, 1 if any fail.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/ClaudeMeter.swift"

log() { printf '[L1] %s\n' "$*" >&2; }

fails=0
failed() { fails=$((fails + 1)); }

# Check 1 — every Timer closure must use [weak self] to avoid retain cycles
# that would prevent the AppDelegate from deallocating (not relevant here since
# the AppDelegate lives the whole app lifetime, but enforced as defensive code).
log "check: Timer.scheduledTimer captures use [weak self]"
bad=$(awk '
    /Timer\.scheduledTimer/ { ts=NR }
    ts && NR>=ts && NR<=ts+3 && /\{ \[weak self\]/ { ts=0 }
    ts && NR==ts+3 { print FILENAME ":" ts ": Timer without [weak self]"; ts=0 }
' "$SRC" || true)
if [ -n "$bad" ]; then echo "$bad" >&2; failed; fi

# Check 2 — no force-unwrap on JS evaluation results (would crash on nil).
log "check: no force-unwrap on evaluateJavaScript callbacks"
bad=$(grep -nE 'evaluateJavaScript.*\{[^}]*as!' "$SRC" || true)
if [ -n "$bad" ]; then echo "$SRC:$bad" >&2; failed; fi

# Check 3 — both scrape paths exist (defense in depth: structured + direct).
log "check: both scrape paths present (scrapeUsageJS + scrapeSessionPercentageJS)"
grep -q 'static let scrapeUsageJS' "$SRC" || { echo "$SRC: missing scrapeUsageJS" >&2; failed; }
grep -q 'static let scrapeSessionPercentageJS' "$SRC" || { echo "$SRC: missing scrapeSessionPercentageJS (badge has no fallback path)" >&2; failed; }

# Check 4 — badge fallback wired into updateBadgeFromModel.
log "check: updateBadgeFromModel uses scrapeSessionPercentageJS as fallback"
if ! awk '/func updateBadgeFromModel/,/^    }$/' "$SRC" | grep -q scrapeSessionPercentageJS; then
    echo "$SRC: updateBadgeFromModel does not fall back to scrapeSessionPercentageJS" >&2
    failed
fi

# Check 5 — empty-scrape reset is counter-gated, not bare. A bare reset on
# every empty scrape causes visible flicker because transient empties happen
# during normal React renders. A counter-gated reset (≥ N consecutive empties)
# distinguishes real failures from rendering jitter.
log "check: scrapeAndDistribute reset is counter-gated (no bare empty reset)"
sd=$(awk '/func scrapeAndDistribute/,/^    }$/' "$SRC")
if ! echo "$sd" | grep -q 'consecutiveEmptyScrapes'; then
    echo "$SRC: scrapeAndDistribute does not use a consecutiveEmptyScrapes counter" >&2
    failed
fi
if ! echo "$sd" | grep -q 'emptyScrapeFailureThreshold'; then
    echo "$SRC: scrapeAndDistribute does not gate reset on emptyScrapeFailureThreshold" >&2
    failed
fi

# Check 6 — popover.isShown guard on badge updates (anti-flicker).
log "check: updateBadgeFromModel guards on popover.isShown"
if ! awk '/func updateBadgeFromModel/,/^    }$/' "$SRC" | grep -q 'popover?.isShown != true'; then
    echo "$SRC: updateBadgeFromModel missing popover.isShown guard (will cause flicker)" >&2
    failed
fi

# Check 7 — startRefreshTimer/stopRefreshTimer are paired in every state transition.
log "check: every popoverDidClose/togglePopover restart of timer goes through startRefreshTimer"
bad=$(grep -nE 'startBadgePolling|startPolling[^_a-zA-Z]' "$SRC" || true)
if [ -n "$bad" ]; then echo "$bad" >&2; echo "  ^ stale v1.7 timer API references found" >&2; failed; fi

# Check 8 — every status item title change goes through setBadgeTitle.
# Direct `statusItem.button?.title = "..."` assignments bypass the instrumented
# logger, breaking the L3 smoke test's stderr-based verification.
log "check: no direct statusItem title assignments (must use setBadgeTitle)"
bad=$(grep -nE 'statusItem\.button\??\.title\s*=' "$SRC" || true)
if [ -n "$bad" ]; then
    echo "$bad" >&2
    echo "  ^ replace with setBadgeTitle(...) so L3 smoke can detect updates" >&2
    failed
fi
log "check: setBadgeTitle helper is defined"
grep -q 'func setBadgeTitle' "$SRC" || { echo "$SRC: setBadgeTitle helper missing" >&2; failed; }

if [ "$fails" -gt 0 ]; then
    log "FAIL: $fails check(s) failed"
    exit 1
fi
log "PASS"
