#!/usr/bin/env bash
# L0 — Build verification.
# Compiles ClaudeMeter.swift to a fresh binary and verifies it launches without
# crashing. Output: writes binary path to stdout on success, exits non-zero on fail.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/ClaudeMeter.swift"
OUT="${CLAUDEMETER_QA_BIN:-/tmp/ClaudeMeter.qa}"

log() { printf '[L0] %s\n' "$*" >&2; }

[ -f "$SRC" ] || { log "FAIL: source not found at $SRC"; exit 1; }

log "compiling $SRC"
swiftc "$SRC" \
    -framework Cocoa \
    -framework WebKit \
    -framework Security \
    -lsqlite3 \
    -parse-as-library \
    -O \
    -o "$OUT"

[ -x "$OUT" ] || { log "FAIL: binary not produced"; exit 1; }
log "compiled: $OUT ($(stat -f%z "$OUT") bytes)"

# Smoke-launch: start, wait 4s, verify still alive, then terminate.
# 4s is enough for a crash on launch (cookie import, WKWebView init, status item
# attach) without waiting for the page to actually load.
log "smoke-launching"
"$OUT" >/tmp/claudemeter.qa.stdout.log 2>/tmp/claudemeter.qa.stderr.log &
PID=$!
sleep 4

if kill -0 "$PID" 2>/dev/null; then
    log "alive after 4s (pid $PID), terminating"
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
else
    log "FAIL: process exited within 4s"
    log "--- stdout ---"
    sed 's/^/  /' /tmp/claudemeter.qa.stdout.log >&2 || true
    log "--- stderr ---"
    sed 's/^/  /' /tmp/claudemeter.qa.stderr.log >&2 || true
    exit 1
fi

log "PASS"
echo "$OUT"
