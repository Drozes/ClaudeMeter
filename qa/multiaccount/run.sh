#!/usr/bin/env bash
# Multi-account flow test (not part of qa.sh: about 2 minutes; briefly opens
# login windows and the popover). Builds ClaudeMeter.swift + testhooks.swift
# with -D CLAUDEMETER_TESTHOOKS into an isolated bundle
# (com.local.ClaudeMeter.qa.multi: own prefs domain, own Application Support
# folder, own WebKit stores) and runs two scenarios through the real
# AppDelegate / AccountController code paths, checking the log:
#   A. accounts: three seeded accounts (primary + two secondaries on empty
#      isolated stores), signed-out detection without windows, Accounts menu,
#      staggered timers, rename, add, cancelled add, requested login window,
#      removal (record, exact-ID keys, history, WebKit store), orphan sweep.
#   B. badge and popover: one account "47%", two accounts "P 47% | W --" and
#      "P 47% | W 12%", slot reassignment, both-hidden fallback, labels, a
#      signed-out side, three accounts stacked in the popover, back to one.
#
# The primary account is real: like L0/L3 it imports Claude Desktop cookies
# (Claude Safe Storage Keychain item) into this bundle's own default store and
# fetches live usage. Never touches the installed app's domain or folder, and
# never any Claude Code-credentials Keychain item.
#
# Usage: qa/multiaccount/run.sh [--keep]   (--keep leaves the test domain/folders)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUNDLE_ID="com.local.ClaudeMeter.qa.multi"
OUT="${CLAUDEMETER_QA_MULTI_BIN:-/tmp/ClaudeMeter.qamulti}"
APP="$OUT.app"
LOGDIR="${CLAUDEMETER_QA_MULTI_LOGDIR:-/tmp}"
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

# run_app <log> <actions>: launch, wait for QA-DONE (max 150s), stop.
run_app() {
    local logfile="$1" actions="$2"
    "$APP/Contents/MacOS/$NAME" -declinedMoveToApplications YES -qa.actions "$actions" >/dev/null 2>"$logfile" &
    local pid=$!
    for _ in $(seq 1 150); do
        grep -q "QA-DONE" "$logfile" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

LOG=""
L() { sed -E 's/^.*(QA-|\[ClaudeMeter\])/\1/' "$LOG"; }
# QA-* lines logged by the Nth action named $1 ("dump", "badge", "popover").
nth() { L | grep '^QA-' | awk -v a="QA-ACTION $1" -v n="$2" '/^QA-ACTION/ { if ($0 == a) { c++; on = (c == n) } else on = 0; next } on'; }
dump() { nth dump "$1"; }
badge() { nth badge "$1" | sed -n "s/^QA-BADGE title='\(.*\)'$/\1/p"; }

# ------------------------------------------------------------ scenario A
log "scenario A: account flows"
cleanup
U1=$(uuidgen); U2=$(uuidgen); U3=$(uuidgen); S1=$(uuidgen); S2=$(uuidgen)
defaults write "$BUNDLE_ID" accounts.migrationVersion -int 1
defaults write "$BUNDLE_ID" showMenuBarBadge -bool YES
defaults write "$BUNDLE_ID" accounts.list -string "{\"schema\":1,\"accounts\":[
 {\"id\":\"primary\",\"displayName\":\"Personal\",\"badgeLabel\":\"P\",\"badgeSlot\":\"left\",\"orgPinned\":false},
 {\"id\":\"$U1\",\"displayName\":\"Work\",\"badgeLabel\":\"W\",\"badgeSlot\":\"right\",\"orgPinned\":true,\"orgUUID\":\"00000000-0000-0000-0000-000000000001\",\"storeIdentifier\":\"$S1\"},
 {\"id\":\"$U2\",\"displayName\":\"Side\",\"badgeLabel\":\"S\",\"badgeSlot\":\"hidden\",\"orgPinned\":false,\"storeIdentifier\":\"$S2\"},
 {\"id\":\"$U3\",\"displayName\":\"Broken\",\"badgeLabel\":\"B\",\"badgeSlot\":\"hidden\",\"orgPinned\":false}]}"

A="dump,wait:10,dump,seedKeys:1,seedKeys:2,keys:1,keys:2,rename:2:Consulting,addSynthetic:Fourth,wait:6,dump"
A="$A,addThenCancel:Temp,wait:3,dump,signIn:1,wait:3,dump,closeLogin:1,wait:3"
A="$A,remove:2,wait:6,keys:1,dump,makeOrphanStore,wait:4,sweep,wait:6,done"
LOG="$LOGDIR/claudemeter.qa.multi.A.log"
run_app "$LOG" "$A"
log "log: $LOG"

check "A finished" 'grep -q QA-DONE "$LOG"'
check "three accounts loaded" 'dump 1 | grep -q "QA-STATE accounts=3"'
check "secondaries signed out (empty stores, confirmed by API)" \
      '[ "$(dump 2 | grep -c "primary=false signedOut=true")" = 2 ] && [ "$(L | grep -c "signed out (.*organizations HTTP 40[13])")" -ge 2 ]'
check "no window opened on its own" 'dump 2 | grep -q "QA-WINDOWS visible=\[\]"'
check "menu offers Sign In Again to Work" 'dump 2 | grep "QA-MENU" | grep -q "Sign In Again to Work"'
check "menu has Accounts submenu with Remove for secondaries" 'dump 2 | grep "QA-MENU" | grep -q "Accounts\[.*Remove"'
check "menu has Badge Position and Badge Label per account" 'dump 2 | grep "QA-MENU" | grep -q "Badge Position\[Left | Right | Hidden\] | Badge Label (W)"'
check "record without a store is kept and listed as unavailable with Remove" 'dump 2 | grep "QA-MENU" | grep -q "Broken (unavailable)\[Remove…\]" && L | grep -q "unavailable: missing or invalid store identifier"'
check "primary has no Remove item" '! dump 2 | grep "QA-MENU" | grep -qE "Personal[^]]*\[[^]]*Remove"'
check "timers staggered (offset logged for secondaries)" 'L | grep -q "startRefreshTimer: .*offset=[0-9]*s"'
check "seeded keys counted" 'L | grep -q "QA-KEYS index=2 .* count=9"'
check "rename applied with default label" 'dump 3 | grep -q "name=Consulting label=C"'
check "fourth account added, slot hidden (right taken)" 'dump 3 | grep -q "name=Fourth label=F slot=hidden"'
check "four accounts after add" 'dump 3 | grep -q "QA-STATE accounts=4 pending=0 saved=5"'
check "cancelled add discarded" 'L | grep -q "add account cancelled before sign-in"'
check "cancelled add left no account" 'dump 4 | grep -q "QA-STATE accounts=4 pending=0 saved=5"'
check "login window opens only on request" 'dump 5 | grep -q "QA-WINDOWS visible=\[\"Sign in to Claude: Work\"\]"'
check "login check logs state changes only" '[ "$(L | grep -c "loginCheck for account")" -le 3 ]'
check "removed: keys, record, history gone" 'L | grep -q "QA-REMOVED .* keysLeft=0 recordLeft=false historyLeft=false"'
check "other account keys untouched" '[ "$(L | grep -c "QA-KEYS index=1 .* count=9")" = 2 ]'
check "three accounts after remove" 'dump 6 | grep -q "QA-STATE accounts=3 pending=0 saved=4"'
check "orphan store found and removed by sweep" 'L | grep -q "data store sweep: [0-9]* found, 1 orphaned"'
check "data stores deleted (cancelled add, removed account, orphan)" '[ "$(L | grep -c "data store removed")" -ge 3 ]'
SAVED_STORES=$(defaults read "$BUNDLE_ID" accounts.list 2>/dev/null | grep -oE '"storeIdentifier":"[0-9A-F-]+"' | grep -oE '[0-9A-F-]{36}' | tr '[:upper:]' '[:lower:]' | sort | tr '\n' ' ')
DISK_STORES=$(ls "$HOME/Library/WebKit/$BUNDLE_ID/WebsiteDataStore" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort | tr '\n' ' ')
log "saved store ids: $SAVED_STORES"
log "on-disk stores:  $DISK_STORES"
check "on-disk WebKit stores match saved accounts (removed and orphan deleted)" '[ -n "$SAVED_STORES" ] && [ "$SAVED_STORES" = "$DISK_STORES" ]'
check "A: no secret-looking values logged" '! grep -qiE "sessionKey=|Bearer |@[a-z0-9.-]+\.[a-z]{2,}" "$LOG"'

# ------------------------------------------------------------ scenario B
log "scenario B: badge and popover"
cleanup
defaults write "$BUNDLE_ID" accounts.migrationVersion -int 1
defaults write "$BUNDLE_ID" showMenuBarBadge -bool YES
defaults write "$BUNDLE_ID" accounts.list -string '{"schema":1,"accounts":[{"id":"primary","displayName":"Personal","badgeLabel":"P","badgeSlot":"left","orgPinned":false}]}'

B="wait:4,inject:0:47,badge,popover"                                    # badge 1, popover 1
B="$B,addSynthetic:Work,wait:10,badge"                                   # badge 2
B="$B,inject:1:12,badge"                                                 # badge 3
B="$B,setSlot:1:left,badge"                                              # badge 4
B="$B,setSlot:0:right,badge"                                             # badge 5
B="$B,setSlot:1:hidden,setSlot:0:hidden,badge,dump"                      # badge 6, dump 1
B="$B,setSlot:0:left,setSlot:1:right,setLabel:0:Me,badge"                # badge 7
B="$B,signOut:1,badge"                                                   # badge 8
B="$B,setLabel:1:w |%x,badge"                                            # badge 9
B="$B,addSynthetic:Third,wait:10,openPopover,wait:10,inject:1:12,inject:2:33,inject:0:47,wait:3,popover" # popover 2
B="$B,closePopover,wait:1,dump"                                          # dump 2
B="$B,remove:2,remove:1,wait:3,badge,popover,done"                       # badge 10, popover 3
LOG="$LOGDIR/claudemeter.qa.multi.B.log"
run_app "$LOG" "$B"
log "log: $LOG"
for i in 1 2 3 4 5 6 7 8 9 10; do log "  badge $i: '$(badge $i)'"; done
for i in 1 2 3; do log "  $(nth popover $i | grep QA-POPOVER)"; done

check "B finished" 'grep -q QA-DONE "$LOG"'
check "one account: plain percentage, no label" '[ "$(badge 1)" = "47%" ]'
check "one account: popover is the usage view itself" 'nth popover 1 | grep -q "mode=single usageViewIsContent=true"'
check "two accounts, both slots, signed-out side: P 47% | W --" '[ "$(badge 2)" = "P 47% | W --" ]'
check "two slots: P 47% | W 12%" '[ "$(badge 3)" = "P 47% | W 12%" ]'
check "slot reassignment moves occupant to hidden: W 12%" '[ "$(badge 4)" = "W 12%" ]'
check "right then left order: W 12% | P 47%" '[ "$(badge 5)" = "W 12% | P 47%" ]'
check "both hidden falls back to primary: P 47%" '[ "$(badge 6)" = "P 47%" ]'
check "custom label: Me 47% | W 12%" '[ "$(badge 7)" = "Me 47% | W 12%" ]'
check "signed-out side shows two hyphens: Me 47% | W --" '[ "$(badge 8)" = "Me 47% | W --" ]'
check "both-hidden fallback noted in the primary's Badge Position menu" 'dump 1 | grep "QA-MENU" | grep -q "Personal[^[]*\[[^]]*Badge Position\[Left | Right | Hidden | Shown on badge: no account has a position\]"'
check "label sanitized (no spaces, | or %): Me 47% | wx --" '[ "$(badge 9)" = "Me 47% | wx --" ]'
check "three accounts stacked in the popover, all with usage, measured while shown" 'nth popover 2 | grep -qE "mode=multi sections=3 \[usage:[0-9]+,usage:[0-9]+,usage:[0-9]+\] .* shown=true"'
POP2=$(nth popover 2 | grep QA-POPOVER)
TOTAL=$(echo "$POP2" | sed -nE 's/.*total=([0-9]+).*/\1/p'); CSIZE=$(echo "$POP2" | sed -nE 's/.*contentSize=([0-9]+).*/\1/p')
check "popover sized to the sum of the sections (total=$TOTAL contentSize=$CSIZE)" \
      '[ -n "$TOTAL" ] && [ -n "$CSIZE" ] && [ "$TOTAL" -gt 300 ] && { { [ $((CSIZE - TOTAL)) -le 3 ] && [ $((TOTAL - CSIZE)) -le 3 ]; } || [ "$CSIZE" -ge 1100 ]; }'
check "badge slot and label persisted" 'dump 2 | grep -q "name=Personal label=Me slot=left"'
check "back to one account: plain percentage again" '[ "$(badge 10)" = "47%" ]'
check "back to one account: popover is the usage view itself" 'nth popover 3 | grep -q "mode=single usageViewIsContent=true"'
check "B: no secret-looking values logged" '! grep -qiE "sessionKey=|Bearer |@[a-z0-9.-]+\.[a-z]{2,}" "$LOG"'

if [ "$KEEP" = 0 ]; then
    cleanup
    log "cleaned up $BUNDLE_ID domain and folders"
fi

if [ "$fails" -gt 0 ]; then log "FAIL: $fails check(s)"; exit 1; fi
log "PASS"
