#!/usr/bin/env bash
# Multi-account flow test (not part of qa.sh: ~45s, opens two login windows
# briefly). Builds ClaudeMeter.swift + testhooks.swift with
# -D CLAUDEMETER_TESTHOOKS into an isolated bundle (com.local.ClaudeMeter.qa.multi,
# own prefs domain, own Application Support folder, own WebKit stores), seeds
# three accounts (primary + two synthetic secondaries on empty isolated
# stores), drives add / cancel / rename / sign-in window / remove through the
# real AppDelegate and AccountController code paths, and checks the log.
#
# The primary account is real: like L0/L3 it imports Claude Desktop cookies
# (Claude Safe Storage Keychain item) into this bundle's own default store
# and fetches live usage. Never touches the installed app's domain or folder,
# and never any Claude Code-credentials Keychain item.
#
# Usage: qa/multiaccount/run.sh [--keep]   (--keep leaves the test domain/folders)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUNDLE_ID="com.local.ClaudeMeter.qa.multi"
OUT="${CLAUDEMETER_QA_MULTI_BIN:-/tmp/ClaudeMeter.qamulti}"
APP="$OUT.app"
LOG="${CLAUDEMETER_QA_MULTI_LOG:-/tmp/claudemeter.qa.multi.log}"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

log() { printf '[MA] %s\n' "$*" >&2; }
fails=0
check() { if (set +o pipefail; eval "$2"); then log "PASS $1"; else log "FAIL $1"; fails=$((fails + 1)); fi; }

case "$(printf '%s' "$APP" | tr '[:upper:]' '[:lower:]')" in
    /applications/*|*/claudemeter.app) log "refusing to build into $APP"; exit 1 ;;
esac

log "compiling with test hooks"
swiftc "$REPO/ClaudeMeter.swift" "$HERE/testhooks.swift" \
    -D CLAUDEMETER_TESTHOOKS \
    -framework Cocoa -framework WebKit -framework Security -lsqlite3 \
    -parse-as-library -O -o "$OUT" || { log "FAIL: compile"; exit 1; }

NAME="$(basename "$OUT")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT" "$APP/Contents/MacOS/$NAME"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>$NAME</string>
<key>CFBundleName</key><string>ClaudeMeter QA Multi</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0</string>
<key>CFBundleVersion</key><string>0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

cleanup() {
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    ( cd "$HOME/Library" && rm -rf "Application Support/$BUNDLE_ID" "Caches/$BUNDLE_ID" "WebKit/$BUNDLE_ID" \
        "HTTPStorages/$BUNDLE_ID" "HTTPStorages/$BUNDLE_ID.binarycookies" "Preferences/$BUNDLE_ID.plist" ) 2>/dev/null
}

# Fresh, isolated prefs domain and folders, with three accounts.
cleanup
U1=$(uuidgen); U2=$(uuidgen); S1=$(uuidgen); S2=$(uuidgen)
defaults write "$BUNDLE_ID" accounts.migrationVersion -int 1
defaults write "$BUNDLE_ID" showMenuBarBadge -bool YES
defaults write "$BUNDLE_ID" accounts.list -string "{\"schema\":1,\"accounts\":[
 {\"id\":\"primary\",\"displayName\":\"Personal\",\"badgeLabel\":\"P\",\"badgeSlot\":\"left\",\"orgPinned\":false},
 {\"id\":\"$U1\",\"displayName\":\"Work\",\"badgeLabel\":\"W\",\"badgeSlot\":\"right\",\"orgPinned\":true,\"orgUUID\":\"00000000-0000-0000-0000-000000000001\",\"storeIdentifier\":\"$S1\"},
 {\"id\":\"$U2\",\"displayName\":\"Side\",\"badgeLabel\":\"S\",\"badgeSlot\":\"hidden\",\"orgPinned\":false,\"storeIdentifier\":\"$S2\"}]}"

ACTIONS="dump,wait:10,dump,seedKeys:1,seedKeys:2,keys:1,keys:2,rename:2:Consulting,addSynthetic:Fourth,wait:6,dump"
ACTIONS="$ACTIONS,addThenCancel:Temp,wait:3,dump,signIn:1,wait:3,dump,closeLogin:1,wait:3"
ACTIONS="$ACTIONS,remove:2,wait:6,keys:1,dump,done"

log "running (log: $LOG)"
"$APP/Contents/MacOS/$NAME" -declinedMoveToApplications YES -qa.actions "$ACTIONS" >/dev/null 2>"$LOG" &
PID=$!
for _ in $(seq 1 90); do
    grep -q "QA-DONE" "$LOG" 2>/dev/null && break
    kill -0 "$PID" 2>/dev/null || break
    sleep 1
done
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true

L() { sed -E 's/^.*(QA-|\[ClaudeMeter\])/\1/' "$LOG"; }
# QA-* lines logged by the Nth "dump" action.
dump() { L | grep '^QA-' | awk -v n="$1" '/^QA-ACTION/ { if ($0 == "QA-ACTION dump") { c++; on = (c == n) } else on = 0; next } on'; }

check "finished" 'grep -q QA-DONE "$LOG"'
check "three accounts loaded" 'dump 1 | grep -q "QA-STATE accounts=3"'
check "secondaries signed out (empty stores), primary not marked by them" \
      '[ "$(dump 2 | grep -c "primary=false signedOut=true")" = 2 ]'
check "no window opened on its own" 'dump 2 | grep -q "QA-WINDOWS visible=\[\]"'
check "menu offers Sign In Again to Work" 'dump 2 | grep "QA-MENU" | grep -q "Sign In Again to Work"'
check "menu has Accounts submenu with Remove for secondaries" 'dump 2 | grep "QA-MENU" | grep -q "Accounts\[.*Remove"'
check "primary has no Remove item" '! dump 2 | grep "QA-MENU" | grep -qE "Personal[^]]*\[[^]]*Remove"'
check "timers staggered (offset logged for secondaries)" 'L | grep -q "startRefreshTimer: .*offset=[0-9]*s"'
check "seeded keys counted" 'L | grep -q "QA-KEYS index=2 .* count=9"'
check "rename applied with default label" 'dump 3 | grep -q "name=Consulting label=C"'
check "fourth account added, slot hidden (right taken)" 'dump 3 | grep -q "name=Fourth label=F slot=hidden"'
check "four accounts after add" 'dump 3 | grep -q "QA-STATE accounts=4 pending=0 saved=4"'
check "cancelled add discarded" 'L | grep -q "add account cancelled before sign-in"'
check "cancelled add left no account" 'dump 4 | grep -q "QA-STATE accounts=4 pending=0 saved=4"'
check "login window opens only on request" 'dump 5 | grep -q "QA-WINDOWS visible=\[\"Sign in to Claude: Work\"\]"'
check "removed: keys, record, history gone" 'L | grep -q "QA-REMOVED .* keysLeft=0 recordLeft=false historyLeft=false"'
check "other account keys untouched" '[ "$(L | grep -c "QA-KEYS index=1 .* count=9")" = 2 ]'
check "data stores deleted (cancelled add + removed)" '[ "$(L | grep -c "data store removed")" -ge 2 ]'
check "three accounts after remove" 'dump 6 | grep -q "QA-STATE accounts=3 pending=0 saved=3"'
SAVED_STORES=$(defaults read "$BUNDLE_ID" accounts.list 2>/dev/null | grep -oE '"storeIdentifier":"[0-9A-F-]+"' | grep -oE '[0-9A-F-]{36}' | tr '[:upper:]' '[:lower:]' | sort | tr '\n' ' ')
DISK_STORES=$(ls "$HOME/Library/WebKit/$BUNDLE_ID/WebsiteDataStore" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort | tr '\n' ' ')
log "saved store ids: $SAVED_STORES"
log "on-disk stores:  $DISK_STORES"
check "on-disk WebKit stores match saved accounts (removed ones deleted)" '[ -n "$SAVED_STORES" ] && [ "$SAVED_STORES" = "$DISK_STORES" ]'
check "no secret-looking values logged" '! grep -qiE "sessionKey=|Bearer |@[a-z0-9.-]+\.[a-z]{2,}" "$LOG"'

if [ "$KEEP" = 0 ]; then
    cleanup
    log "cleaned up $BUNDLE_ID domain and folders"
fi

if [ "$fails" -gt 0 ]; then log "FAIL: $fails check(s)"; exit 1; fi
log "PASS"
