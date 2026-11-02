#!/usr/bin/env bash
# L3 — Smoke test.
#
# Strategy: launch a fresh QA build with `-showMenuBarBadge YES` and verify
# that the badge title changes to a real percentage, by parsing the
# instrumented stderr log (`[ClaudeMeter] badge title: '...' -> '47%' (...)`).
# OCR of the actual menu bar is a supplementary check — Macs with notches
# often hide status items, making OCR unreliable as a primary signal.
#
# Requires Claude Desktop signed in (the app imports cookies from there). On a
# machine without it, the badge will stay at "—%" or "—%"-only changes will
# show up, and this test will FAIL with a clear auth-missing message.

set -uo pipefail

QA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE_DIR="$QA_DIR/smoke"
BIN="${CLAUDEMETER_QA_BIN:-/tmp/ClaudeMeter.qa}"
OCR="$SMOKE_DIR/ocr"
SHOT="${CLAUDEMETER_QA_SHOT:-/tmp/claudemeter.qa.menubar.png}"
STDERR="${CLAUDEMETER_QA_STDERR:-/tmp/claudemeter.qa.stderr.log}"
STDOUT="${CLAUDEMETER_QA_STDOUT:-/tmp/claudemeter.qa.stdout.log}"
TIMEOUT="${CLAUDEMETER_QA_TIMEOUT:-45}"

log() { printf '[L3] %s\n' "$*" >&2; }

# 1. Make sure binary is built and current. L0 also wraps it in a minimal
#    .app bundle (UNUserNotificationCenter needs one); launch that copy.
LAUNCH="$BIN.app/Contents/MacOS/$(basename "$BIN")"
if [ ! -x "$BIN" ] || [ ! -x "$LAUNCH" ] || [ "$QA_DIR/../ClaudeMeter.swift" -nt "$BIN" ] \
    || [ "$BIN" -nt "$LAUNCH" ]; then
    log "binary stale or missing — rebuilding via L0"
    "$QA_DIR/build.sh" >/dev/null || { log "FAIL: L0 build failed"; exit 1; }
fi

# 2. Build the OCR helper if needed (best-effort; L3 doesn't fail if absent).
if [ ! -x "$OCR" ] || [ "$SMOKE_DIR/ocr.swift" -nt "$OCR" ]; then
    log "compiling OCR helper"
    swiftc "$SMOKE_DIR/ocr.swift" -framework Vision -framework AppKit -O -o "$OCR" 2>/dev/null \
        || log "warn: OCR helper compile failed (supplementary check will be skipped)"
fi

# 3. Tear down any prior ClaudeMeter so we're observing OUR process.
pkill -x ClaudeMeter 2>/dev/null || true
pkill -f "$(basename "$BIN")" 2>/dev/null || true
sleep 0.5

# 4. Launch with badge forced ON (NSArgumentDomain override).
#    -declinedMoveToApplications YES suppresses the modal "Move to
#    Applications?" alert that a bundled copy outside /Applications triggers.
#    -lastBadgePercentage 0 blanks the cached badge value the QA bundle's own
#    prefs domain kept from an earlier run, so the launch-time restore shows
#    the placeholder instead of an old percentage.
log "launching $LAUNCH with -showMenuBarBadge YES"
: > "$STDERR"
"$LAUNCH" -showMenuBarBadge YES -declinedMoveToApplications YES \
    -lastBadgePercentage 0 >"$STDOUT" 2>"$STDERR" &
PID=$!

cleanup() {
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# 5. Poll: tail stderr for "badge title: '...' -> '<digits>%'".
#    A real percentage (not "—%", not "") in the *target* of the transition
#    proves the data pipeline reached the badge writer.
log "watching stderr for ${TIMEOUT}s for a real percentage badge update"
START=$(date +%s)
while :; do
    NOW=$(date +%s)
    if ! kill -0 "$PID" 2>/dev/null; then
        log "FAIL: app exited unexpectedly"
        log "--- last 20 lines of stderr ---"
        tail -20 "$STDERR" >&2 || true
        exit 1
    fi
    if [ $((NOW - START)) -ge "$TIMEOUT" ]; then
        log "FAIL: timed out after ${TIMEOUT}s waiting for badge update"
        log "--- last 30 lines of stderr ---"
        tail -30 "$STDERR" >&2 || true
        exit 1
    fi

    # Look for an arrow target that's a real percentage.
    # Match: badge title: '<anything>' -> '<digits>%' (
    # Transitions with reason "applyBadgeVisibility cached=" are excluded: they
    # restore a cached value at launch and prove nothing about fetching.
    line=$(grep -E "badge title: '[^']*' -> '[0-9]+%'" "$STDERR" 2>/dev/null \
        | grep -v "(applyBadgeVisibility cached=" | tail -1)
    if [ -n "$line" ]; then
        badge=$(echo "$line" | sed -E "s/.*-> '([0-9]+%)'.*/\1/")
        log "PASS: badge updated to $badge"
        log "  log line: $(echo "$line" | sed 's/.*\[ClaudeMeter\]/  [ClaudeMeter]/')"

        # Supplementary OCR check (informational only — failure here doesn't fail L3).
        if [ -x "$OCR" ]; then
            sleep 1  # let the rendered status item settle
            if screencapture -x -t png -R 0,0,4000,30 "$SHOT" 2>/dev/null; then
                ocr_text=$("$OCR" "$SHOT" 2>/dev/null | tr '\n' ' ' | tr -s ' ')
                if echo "$ocr_text" | grep -qE '[0-9]+%'; then
                    log "  OCR confirms visible: $(echo "$ocr_text" | grep -oE '[0-9]+%' | head -1)"
                else
                    log "  OCR did not pick up percentage (likely notch/contrast — log signal is authoritative)"
                fi
            fi
        fi
        exit 0
    fi

    sleep 1
done
