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
# distinguishes real failures from rendering jitter. The gate now lives in
# distributeFetchResult since both JSON and DOM paths funnel through it.
log "check: distributeFetchResult is counter-gated (no bare empty reset)"
sd=$(awk '/func distributeFetchResult/,/^    }$/' "$SRC")
if ! echo "$sd" | grep -q 'consecutiveEmptyScrapes'; then
    echo "$SRC: distributeFetchResult does not use a consecutiveEmptyScrapes counter" >&2
    failed
fi
if ! echo "$sd" | grep -q 'emptyScrapeFailureThreshold'; then
    echo "$SRC: distributeFetchResult does not gate reset on emptyScrapeFailureThreshold" >&2
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

# Check 9 — JSON-primary fetch helper exists.
log "check: fetchViaJSON is defined"
grep -q 'func fetchViaJSON' "$SRC" || { echo "$SRC: fetchViaJSON missing (JSON foundation regressed)" >&2; failed; }

# Check 10 — DOM scrapers stayed in place. The JSON path is undocumented and
# may rotate; the DOM scrape MUST remain as a working fallback.
log "check: DOM scrape constants survive (scrapeUsageJS + scrapeSessionPercentageJS)"
grep -q 'static let scrapeUsageJS' "$SRC" || { echo "$SRC: scrapeUsageJS removed (DOM fallback gone)" >&2; failed; }
grep -q 'static let scrapeSessionPercentageJS' "$SRC" || { echo "$SRC: scrapeSessionPercentageJS removed (DOM badge fallback gone)" >&2; failed; }

# Check 11 — fetch outcome telemetry is centralized in logFetchOutcome.
# Direct NSLog("[ClaudeMeter] fetch path=...") writes outside the helper bypass
# the QA pipeline's stderr-based verification (mirrors check 8 for setBadgeTitle).
log "check: every 'fetch path=' NSLog goes through logFetchOutcome"
bad=$(awk '
    /func logFetchOutcome/ { in_helper=1; brace=0 }
    in_helper {
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if (c == "{") brace++
            else if (c == "}") { brace--; if (brace == 0) { in_helper=0; next } }
        }
        next
    }
    /NSLog.*fetch path=/ { print FILENAME ":" NR ": " $0 }
' "$SRC" || true)
if [ -n "$bad" ]; then
    echo "$bad" >&2
    echo "  ^ replace direct NSLog with logFetchOutcome(path:outcome:detail:)" >&2
    failed
fi
grep -q 'func logFetchOutcome' "$SRC" || { echo "$SRC: logFetchOutcome helper missing" >&2; failed; }

# Check 12 — rollback flag wired up.
log "check: forceDOMOnlyKey is referenced (rollback flag wired)"
grep -q 'forceDOMOnlyKey' "$SRC" || { echo "$SRC: forceDOMOnlyKey missing (no DOM-only rollback path)" >&2; failed; }

# Check 13 — UserNotifications framework is imported (modern API).
log "check: UserNotifications import present"
grep -q '^import UserNotifications' "$SRC" || { echo "$SRC: missing 'import UserNotifications' (notif feature regressed)" >&2; failed; }

# Check 14 — NSUserNotification (deprecated since 10.14) is not used.
log "check: deprecated NSUserNotification absent"
bad=$(grep -nE 'NSUserNotification\b' "$SRC" || true)
if [ -n "$bad" ]; then
    echo "$bad" >&2
    echo "  ^ replace with UNUserNotificationCenter (UserNotifications framework)" >&2
    failed
fi

# Check 15 — requestAuthorization is NOT called inside applicationDidFinishLaunching.
# Asking for notification permission on launch is a known privacy regression;
# auth must be lazy on first fire.
log "check: requestAuthorization not called from applicationDidFinishLaunching"
adfl=$(awk '/func applicationDidFinishLaunching/,/^    }$/' "$SRC")
if echo "$adfl" | grep -q 'requestAuthorization'; then
    echo "$SRC: applicationDidFinishLaunching calls requestAuthorization (consent-on-launch regression)" >&2
    failed
fi

# Check 16 — notifier.evaluate is called exactly once, from inside distributeFetchResult.
log "check: notifier.evaluate has exactly one callsite, inside distributeFetchResult"
total=$(grep -cE 'notifier\.evaluate\(' "$SRC" || true)
if [ "$total" != "1" ]; then
    echo "$SRC: expected 1 callsite for notifier.evaluate, found $total" >&2
    failed
fi
ds=$(awk '/func distributeFetchResult/,/^    }$/' "$SRC")
if ! echo "$ds" | grep -q 'notifier\.evaluate'; then
    echo "$SRC: distributeFetchResult does not call notifier.evaluate (notif seam missing)" >&2
    failed
fi

# Check 17 — every 'notif.fired.' write is paired with a bool(forKey:) idempotency guard.
# A bare write without the read-then-write check would re-fire on every scrape.
log "check: notif.fired.* writes are idempotency-guarded"
fired_writes=$(grep -nE 'set\(true, forKey: firedKey\)' "$SRC" || true)
if [ -n "$fired_writes" ]; then
    if ! grep -qE 'bool\(forKey: firedKey\)' "$SRC"; then
        echo "$SRC: notif.fired.* write without paired bool(forKey:) guard (will re-fire)" >&2
        failed
    fi
fi

# Check 18 — interruptionLevel = .timeSensitive literal present (banner won't be muted by Focus).
log "check: notification interruptionLevel = .timeSensitive present"
grep -q 'interruptionLevel = \.timeSensitive' "$SRC" || {
    echo "$SRC: missing interruptionLevel = .timeSensitive (notifications get suppressed by Focus)" >&2
    failed
}

# Check 19 — cycleKey embedded in string keys is always Int-cast first (no
# floating-point fp drift in the key).
log "check: no string interpolation of cycleKey without Int() cast"
bad=$(grep -nE '\\\(cycleStart\.[a-z]+\)' "$SRC" || true)
if [ -n "$bad" ]; then
    echo "$bad" >&2
    echo "  ^ wrap cycle timestamps with Int(...) before interpolating into UserDefaults keys" >&2
    failed
fi

# Check 20 — peakWindow constant is defined exactly once as a struct (single
# source of truth for the Anthropic peak-hour window; v2.3 feature).
log "check: peakWindow constant defined exactly once as a struct"
peak_count=$(grep -cE '^[[:space:]]*static let peakWindow' "$SRC" || true)
if [ "$peak_count" != "1" ]; then
    echo "$SRC: expected 1 'static let peakWindow' definition, found $peak_count" >&2
    failed
fi
if ! grep -qE 'struct PeakWindow' "$SRC"; then
    echo "$SRC: missing 'struct PeakWindow' definition" >&2
    failed
fi

# Check 21 — countdown ticker is stopped on popover close (battery regression
# guard; the 1Hz timer must NOT keep firing while the popover is hidden).
log "check: popoverDidClose stops the countdown ticker"
pdc=$(awk '/func popoverDidClose/,/^    }$/' "$SRC")
if ! echo "$pdc" | grep -qE 'stopCountdownTicker|countdownTicker\.stop'; then
    echo "$SRC: popoverDidClose does not stop the countdown ticker (battery regression)" >&2
    failed
fi
if ! grep -qE 'func stop\(\)' "$SRC"; then
    echo "$SRC: CountdownTicker.stop() definition missing" >&2
    failed
fi

if [ "$fails" -gt 0 ]; then
    log "FAIL: $fails check(s) failed"
    exit 1
fi
log "PASS"
