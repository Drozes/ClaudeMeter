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

# Wrap the binary in a minimal .app bundle and launch it from there. Since v2.4
# the app calls UNUserNotificationCenter.current() at launch, which throws
# "bundleProxyForCurrentProcess is nil" for an unbundled executable, so a bare
# binary crashes before the 4s check. The bundle uses its own identifier
# (com.local.ClaudeMeter.qa) so QA runs never read or write the installed
# app's preferences domain. L3 (smoke/run.sh) launches the same bundled copy.
NAME="$(basename "$OUT")"
APP="$OUT.app"
# Guard the rm -rf below: never touch an installed app.
case "$APP" in
    /Applications/*|"$HOME"/Applications/*|*/ClaudeMeter.app|ClaudeMeter.app)
        log "FAIL: refusing to replace $APP (looks like an installed app); set CLAUDEMETER_QA_BIN elsewhere"
        exit 1 ;;
esac
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT" "$APP/Contents/MacOS/$NAME"
plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$REPO/Info.plist" 2>/dev/null || echo "0"; }
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.local.ClaudeMeter.qa</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundleName</key>
	<string>ClaudeMeter QA</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$(plist_get CFBundleShortVersionString)</string>
	<key>CFBundleVersion</key>
	<string>$(plist_get CFBundleVersion)</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST
LAUNCH="$APP/Contents/MacOS/$NAME"
log "bundled: $APP"
# A bundled copy outside /Applications triggers AppUpdater's modal
# "Move to Applications?" alert, which blocks the main thread and, if accepted,
# copies the QA bundle into /Applications. Suppress it via the argument domain
# (no persistent defaults write). smoke/run.sh passes the same flag.
NO_MOVE_PROMPT=(-declinedMoveToApplications YES)

# Smoke-launch: start, wait 4s, verify still alive, then terminate.
# 4s is enough for a crash on launch (cookie import, WKWebView init, status item
# attach) without waiting for the page to actually load.
log "smoke-launching"
"$LAUNCH" "${NO_MOVE_PROMPT[@]}" >/tmp/claudemeter.qa.stdout.log 2>/tmp/claudemeter.qa.stderr.log &
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
