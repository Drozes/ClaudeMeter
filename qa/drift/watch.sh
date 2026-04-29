#!/usr/bin/env bash
# L4 — Drift watcher. Long-running.
#
# Repeatedly screenshots the menu bar and OCRs the badge, logging each sample
# to a JSONL file. After WINDOW samples without observing a change, posts a
# system notification ("ClaudeMeter badge stuck"). Catches the *exact* failure
# mode the user hit today: badge appears to render fine, but never updates.
#
# Designed to be run by hand or installed as a launchd agent. Does NOT launch
# ClaudeMeter — assumes the installed app is already running. (We're checking
# real-world behavior, not a synthetic build.)

set -uo pipefail

QA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OCR="$QA_DIR/smoke/ocr"
SHOT="${CLAUDEMETER_DRIFT_SHOT:-/tmp/claudemeter.drift.png}"
LOG="${CLAUDEMETER_DRIFT_LOG:-/tmp/claudemeter.drift.jsonl}"

# Tunables
INTERVAL="${CLAUDEMETER_DRIFT_INTERVAL:-300}"   # 5 min between samples
WINDOW="${CLAUDEMETER_DRIFT_WINDOW:-12}"        # 12 samples (1 hr at 5min) without change → alert
ALERT_COOLDOWN="${CLAUDEMETER_DRIFT_COOLDOWN:-3600}"  # 1 hr between repeat alerts

log() { printf '[L4 %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# Build OCR helper if needed.
if [ ! -x "$OCR" ] || [ "$QA_DIR/smoke/ocr.swift" -nt "$OCR" ]; then
    swiftc "$QA_DIR/smoke/ocr.swift" -framework Vision -framework AppKit -O -o "$OCR" \
        || { log "FAIL: OCR helper compile failed"; exit 1; }
fi

notify() {
    local title="$1" body="$2"
    osascript -e "display notification \"$body\" with title \"$title\"" 2>/dev/null || true
}

last_alert=0
streak_count=0
streak_value=""

log "starting drift watcher: interval=${INTERVAL}s window=${WINDOW} samples log=$LOG"

while :; do
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if ! pgrep -x ClaudeMeter >/dev/null; then
        printf '{"ts":"%s","status":"app_not_running"}\n' "$ts" >>"$LOG"
        sleep "$INTERVAL"; continue
    fi

    if ! screencapture -x -t png -R 0,0,4000,30 "$SHOT" 2>/dev/null; then
        printf '{"ts":"%s","status":"screencap_failed"}\n' "$ts" >>"$LOG"
        sleep "$INTERVAL"; continue
    fi

    text=$("$OCR" "$SHOT" 2>/dev/null | tr '\n' ' ' | tr -s ' ')
    badge=$(echo "$text" | grep -oE '[0-9]+%|—%|--%' | head -1)
    badge="${badge:-?}"

    printf '{"ts":"%s","badge":"%s","ocr":"%s"}\n' \
        "$ts" "$badge" "$(echo "$text" | sed 's/"/\\"/g')" >>"$LOG"

    if [ "$badge" = "$streak_value" ]; then
        streak_count=$((streak_count + 1))
    else
        streak_value="$badge"
        streak_count=1
    fi

    if [ "$streak_count" -ge "$WINDOW" ] && [ "$badge" != "?" ]; then
        now_epoch=$(date +%s)
        if [ $((now_epoch - last_alert)) -ge "$ALERT_COOLDOWN" ]; then
            log "ALERT: badge stuck at '$badge' for $streak_count samples"
            notify "ClaudeMeter QA" "Badge stuck at $badge for $((streak_count * INTERVAL / 60)) min"
            last_alert=$now_epoch
        fi
    fi

    sleep "$INTERVAL"
done
