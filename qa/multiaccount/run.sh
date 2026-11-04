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
# Like L0/L3 it launches with -skipDesktopImport YES -suppressAutoLoginWindow
# YES: no Claude Desktop import, so no Keychain access at all (no prompts);
# the primary account has no session here and shows signed out. Never
# touches the installed app's domain or folder.
#
# Usage: qa/multiaccount/run.sh [--keep]   (--keep leaves the test domain/folders)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUNDLE_ID="com.local.ClaudeMeter.qa.multi"
OUT="${CLAUDEMETER_QA_MULTI_BIN:-/tmp/ClaudeMeter.qamulti}"
APP="$OUT.app"
LOGDIR="${CLAUDEMETER_QA_MULTI_LOGDIR:-/tmp}"
SHOTDIR="${CLAUDEMETER_QA_MULTI_SHOTDIR:-/tmp/claudemeter.qa.multi.shots}"
mkdir -p "$SHOTDIR"
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
    local exe="${RUN_EXE:-$APP/Contents/MacOS/$NAME}"
    # No Claude Desktop import (no Keychain prompt) and no auto-opened login
    # window: the primary account here has no session and shows signed out.
    "$exe" -declinedMoveToApplications YES -skipDesktopImport YES -suppressAutoLoginWindow YES \
        ${RUN_EXTRA:-} -qa.shotDir "$SHOTDIR" -qa.actions "$actions" >/dev/null 2>"$logfile" &
    local pid=$!
    local shots=0
    for _ in $(seq 1 300); do
        grep -q "QA-DONE" "$logfile" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        # Capture the real menu bar for each "QA-SHOT name x y w h" request.
        local n
        n=$(grep -c "QA-SHOT " "$logfile" 2>/dev/null || true)
        while [ "${n:-0}" -gt "$shots" ]; do
            shots=$((shots + 1))
            set -- $(grep "QA-SHOT " "$logfile" | sed -n "${shots}p" | sed -E 's/^.*QA-SHOT //')
            if [ $# -ge 5 ]; then
                screencapture -x -R "$(( $2 - 8 )),$3,$(( $4 + 16 )),$5" "$SHOTDIR/$1-menubar.png" 2>/dev/null || true
            fi
        done
        sleep 0.5
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

A="dump,waitSignedOut:1:60,waitSignedOut:2:60,wait:1,dump,seedKeys:1,seedKeys:2,keys:1,keys:2,rename:2:Consulting,addSynthetic:Fourth,cookies:1,cookies:2,cookies:3,wait:6,dump"
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
check "menu has Badge Position and Badge Label per account" 'dump 2 | grep "QA-MENU" | grep -qE "Badge Position\[Left[^]|]* \| Right[^]|]* \| Hidden[^]|]*\] \| Badge Label \(W\)"'
check "record without a store is kept and listed as unavailable with Remove" 'dump 2 | grep "QA-MENU" | grep -q "Broken (unavailable)\[Remove…\]" && L | grep -q "unavailable: missing or invalid store identifier"'
check "2+ accounts: top-level Import/Sign In hidden, moved into the primary's submenu" 'dump 2 | grep "QA-MENU" | grep -q "^QA-MENU Reload | Import from Claude Desktop{hidden} | Sign In…{hidden} |" && dump 2 | grep "QA-MENU" | grep -qE "Personal[^[]*\[[^]]*Sign In Again… \| Import from Claude Desktop \|"'
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
ck() { L | grep "QA-COOKIES $1 " | tail -1; }
num() { sed -nE "s/.*$1=([0-9]+).*/\1/p"; }
check "cookie write-back only into the account's own store (new account's store empty)" \
      '[ "$(ck 3 | num store)" = 0 ] && [ "$(ck 3 | num writeBacks)" = 0 ] && for i in 1 2; do w=$(ck $i | num writeBacks); st=$(ck $i | num store); [ -n "$w" ] && { [ "$w" = 0 ] || [ "$st" -gt 0 ]; } || exit 1; done'
check "A: no secret-looking values logged" '! grep -qiE "sessionKey=|Bearer |@[a-z0-9.-]+\.[a-z]{2,}" "$LOG"'

# ------------------------------------------------------------ scenario B
log "scenario B: badge and popover"
cleanup
defaults write "$BUNDLE_ID" accounts.migrationVersion -int 1
defaults write "$BUNDLE_ID" showMenuBarBadge -bool YES
defaults write "$BUNDLE_ID" accounts.list -string '{"schema":1,"accounts":[{"id":"primary","displayName":"Personal","badgeLabel":"P","badgeSlot":"left","orgPinned":false}]}'

B="wait:8,inject:0:47,badge,popover"                                    # badge 1, popover 1
B="$B,addSynthetic:Work,waitSignedOut:1:60,wait:1,badge"                 # badge 2
B="$B,inject:1:12,badge"                                                 # badge 3
B="$B,setSlot:1:left,badge"                                              # badge 4
B="$B,setSlot:0:right,badge"                                             # badge 5
B="$B,setSlot:1:hidden,setSlot:0:hidden,badge,dump"                      # badge 6, dump 1
B="$B,setSlot:0:left,setSlot:1:right,setLabel:0:Me,badge"                # badge 7
B="$B,signOut:1,badge"                                                   # badge 8
B="$B,setLabel:1:w |%x,badge"                                            # badge 9
B="$B,addSynthetic:Third,wait:10,openPopover,wait:10,inject:1:12,inject:2:33,inject:0:47,wait:3,popover" # popover 2
B="$B,closePopover,wait:1,dump"                                          # dump 2
B="$B,remove:2,remove:1,wait:3,badge,popover,dump,tiers,done"          # badge 10, popover 3, dump 3
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
check "both-hidden fallback noted in the primary's Badge Position menu" 'dump 1 | grep "QA-MENU" | grep -q "Personal[^[]*\[[^]]*Badge Position\[Left | Right | Hidden{on} | Shown on badge: no account has a position\]"'
check "label sanitized (no spaces, | or %): Me 47% | wx --" '[ "$(badge 9)" = "Me 47% | wx --" ]'
check "three accounts stacked in the popover, all with usage, measured while shown" 'nth popover 2 | grep -qE "mode=multi sections=3 \[usage:[0-9]+,usage:[0-9]+,usage:[0-9]+\] .* shown=true"'
POP2=$(nth popover 2 | grep QA-POPOVER)
TOTAL=$(echo "$POP2" | sed -nE 's/.*total=([0-9]+).*/\1/p'); CSIZE=$(echo "$POP2" | sed -nE 's/.*contentSize=([0-9]+).*/\1/p')
check "popover sized to the sum of the sections (total=$TOTAL contentSize=$CSIZE)" \
      '[ -n "$TOTAL" ] && [ -n "$CSIZE" ] && [ "$TOTAL" -gt 300 ] && { { [ $((CSIZE - TOTAL)) -le 3 ] && [ $((TOTAL - CSIZE)) -le 3 ]; } || [ "$CSIZE" -ge 1100 ]; }'
check "badge slot and label persisted" 'dump 2 | grep -q "name=Personal label=Me slot=left"'
check "back to one account: plain percentage again" '[ "$(badge 10)" = "47%" ]'
check "back to one account: popover is the usage view itself" 'nth popover 3 | grep -q "mode=single usageViewIsContent=true"'
check "one account again: top-level Import and Sign In visible as in v2.8" 'dump 3 | grep "QA-MENU" | grep -q "^QA-MENU Reload | Import from Claude Desktop | Sign In… | Add Account…"'
check "plan tiers: raven maps to Work plan/Team/Enterprise, unknown tiers tidy" 'L | grep -q "QA-TIER default_raven/nil -> Work plan" && L | grep -q "QA-TIER default_raven/team -> Team" && L | grep -q "QA-TIER default_raven/enterprise -> Enterprise" && L | grep -q "QA-TIER default_claude_max_50x/nil -> Max 50x" && L | grep -q "QA-TIER default_foo_bar/nil -> Foo Bar" && L | grep -q "QA-TIER default_/nil -> Unknown plan" && L | grep -q "QA-TIER default_claude_max_20x/nil -> Max 20x"'
check "B: no secret-looking values logged" '! grep -qiE "sessionKey=|Bearer |@[a-z0-9.-]+\.[a-z]{2,}" "$LOG"'

# ------------------------------------------------------------ scenario C
log "scenario C: activity dot and account colours (shots: $SHOTDIR)"
cleanup
defaults write "$BUNDLE_ID" accounts.migrationVersion -int 1
defaults write "$BUNDLE_ID" showMenuBarBadge -bool YES
defaults write "$BUNDLE_ID" accounts.list -string '{"schema":1,"accounts":[{"id":"primary","displayName":"Personal","badgeLabel":"P","badgeSlot":"left","orgPinned":false}]}'
C="wait:8,inject:0:47"
C="$C,forecast:0:0.5,badge,shot:1acct-green"                                     # badge 1
C="$C,forecast:0:3,badge,shot:1acct-gold"                                        # badge 2
C="$C,forecast:0:10,badge,shot:1acct-amber"                                      # badge 3
C="$C,forecast:0:20,badge,shot:1acct-crimson"                                    # badge 4
C="$C,forecast:0:idle,badge,shot:1acct-idle"                                     # badge 5
C="$C,forecast:0:3,dot:off,badge,shot:1acct-dot-off"                             # badge 6
C="$C,dot:on,badge"                                                              # badge 7
C="$C,addSynthetic:Work,wait:10,inject:1:12,forecast:0:3,forecast:1:20,badge,shot:2acct-gold-crimson"  # badge 8
C="$C,signOut:1,badge,shot:2acct-signedout"                                      # badge 9
C="$C,setColor:1:teal,inject:1:12,forecast:1:0.5,badge,shot:2acct-teal-green,popover"   # badge 10, popover 1
C="$C,dot:off,badge,dot:on"                                                      # badge 11
C="$C,setColor:0:chartreuse,dump,done"                                           # dump 1
LOG="$LOGDIR/claudemeter.qa.multi.C.log"
run_app "$LOG" "$C"
log "log: $LOG"
bstyle() { nth badge "$1" | grep QA-BADGESTYLE | sed -E 's/^QA-BADGESTYLE //'; }
for i in 1 2 3 4 5 6 7 8 9 10 11; do log "  badge $i: '$(badge $i)'  $(bstyle $i)"; done
check "C finished" 'grep -q QA-DONE "$LOG"'
check "one account, green band: 47% with a green dot" '[ "$(badge 1)" = "47%" ] && bstyle 1 | grep -q "dots=\[\"green\"\] dotViews=1 tints=\[\]"'
check "gold band" 'bstyle 2 | grep -q "dots=\[\"gold\"\] dotViews=1"'
check "amber band" 'bstyle 3 | grep -q "dots=\[\"amber\"\] dotViews=1"'
check "crimson band" 'bstyle 4 | grep -q "dots=\[\"crimson\"\] dotViews=1"'
check "idle: no dot, plain title" '[ "$(badge 5)" = "47%" ] && bstyle 5 | grep -q "attributed=false dots=\[\] dotViews=0"'
check "toggle off: exactly the v2.8 plain title" '[ "$(badge 6)" = "47%" ] && bstyle 6 | grep -q "attributed=false dots=\[\] dotViews=0 tints=\[\]"'
check "toggle back on: dot returns" 'bstyle 7 | grep -q "dots=\[\"gold\"\] dotViews=1"'
check "two sides, different bands, labels tinted Blue/Purple" '[ "$(badge 8)" = "P 47% | W 12%" ] && bstyle 8 | grep -q "dots=\[\"gold\", \"crimson\"\] dotViews=2 tints=\[\"blue\", \"purple\"\] tintOK=true"'
check "signed-out side: no dot" '[ "$(badge 9)" = "P 47% | W --" ] && bstyle 9 | grep -q "dots=\[\"gold\"\] dotViews=1"'
check "colour change re-tints the label" '[ "$(badge 10)" = "P 47% | W 12%" ] && bstyle 10 | grep -q "dots=\[\"gold\", \"green\"\] dotViews=2 tints=\[\"blue\", \"teal\"\] tintOK=true"'
check "popover headers show account colours" 'nth popover 1 | grep -q "headers=\[\"blue\", \"teal\"\]"'
check "two accounts, dot off: same text, labels still tinted, no dots" '[ "$(badge 11)" = "P 47% | W 12%" ] && bstyle 11 | grep -q "dots=\[\] dotViews=0 tints=\[\"blue\", \"teal\"\]"'
check "dot-only change logged as badge style, not as a title transition" 'L | grep -q "badge style: .47%. dots="'
check "menu: Colour submenu with swatches, current checked" 'dump 1 | grep "QA-MENU" | grep -q "Colour\[Blue{img} | Purple{img} | Indigo{img} | Teal{img}{on} | Cyan{img} | Magenta{img} | Graphite{img} | Brown{img}\]"'
check "menu: account list items carry a colour swatch" 'dump 1 | grep "QA-MENU" | grep -qE "Personal(, signed out)?( \([^)]*\))?\{img\}\[" && dump 1 | grep "QA-MENU" | grep -qE "Work(, signed out)?( \([^)]*\))?\{img\}\["'
check "unknown colour key reads as the default (Blue for primary), raw key kept" 'dump 1 | grep -q "name=Personal .* color=blue colorKey=chartreuse"'
check "new account got the next unused colour, then Teal" 'dump 1 | grep -q "name=Work .* color=teal colorKey=teal"'
for f in 1acct-green 1acct-gold 1acct-amber 1acct-crimson 1acct-idle 1acct-dot-off 2acct-gold-crimson 2acct-signedout 2acct-teal-green; do
    check "renders $f (light/dark/current)" '[ -s "$SHOTDIR/'"$f"'-light.png" ] && [ -s "$SHOTDIR/'"$f"'-dark.png" ] && [ -s "$SHOTDIR/'"$f"'-current.png" ]'
done
check "C: no secret-looking values logged" '! grep -qiE "sessionKey=|Bearer |@[a-z0-9.-]+\.[a-z]{2,}" "$LOG"'

log "scenario C2: relaunch keeps colours"
LOG="$LOGDIR/claudemeter.qa.multi.C2.log"
run_app "$LOG" "wait:4,dump,badge,done"
check "C2: colours survive relaunch (unknown key still default, Teal kept)" \
      'dump 1 | grep -q "name=Personal .* color=blue colorKey=chartreuse" && dump 1 | grep -q "name=Work .* color=teal colorKey=teal"'
check "C2: badge labels tinted after relaunch" 'nth badge 1 | grep -q "tints=\[\"blue\", \"teal\"\] tintOK=true"'

# ------------------------------------------------------------ scenario D
log "scenario D: plan with no session window (weekly only)"
cleanup
defaults write "$BUNDLE_ID" accounts.migrationVersion -int 1
defaults write "$BUNDLE_ID" showMenuBarBadge -bool YES
defaults write "$BUNDLE_ID" lastBadgePercentage.primary -int 2
defaults write "$BUNDLE_ID" accounts.list -string '{"schema":1,"accounts":[{"id":"primary","displayName":"Personal","badgeLabel":"P","badgeSlot":"left","orgPinned":false,"planTier":"default_claude_max_20x","colorKey":"blue"}]}'
D="wait:8,badge"                                             # badge 1: stale cached 2%
D="$D,injectWeekly:0:96,badge"                               # badge 2: one weekly-only fetch, no switch yet
D="$D,injectWeekly:0:96,badge,dump"                          # badge 3: second fetch, switch; dump 1
D="$D,forecastWeekly:0:3,badge"                              # badge 4: weekly forecast -> gold
D="$D,forecast:0:20,badge"                                   # badge 5: session forecast ignored -> still gold
D="$D,renderPopover:weekly-only"
D="$D,inject:0:47,forecast:0:20,badge"                       # badge 6: session window back -> crimson, immediately
D="$D,injectWeeklyDOM:0:88,wait:2,badge"                     # badge 7: DOM weekly-only: XPath first (nil here), then weekly
D="$D,injectWeekly:0:96,injectWeekly:0:96,addSynthetic:Work,waitSignedOut:1:60,inject:1:12,badge"   # badge 8: P 96% | W 12%
D="$D,done"
LOG="$LOGDIR/claudemeter.qa.multi.D.log"
run_app "$LOG" "$D"
log "log: $LOG"
for i in 1 2 3 4 5 6 7 8; do log "  badge $i: '$(badge $i)'  $(bstyle $i)"; done
check "D finished" 'grep -q QA-DONE "$LOG"'
check "stale cached session value shown before the first fetch" '[ "$(badge 1)" = "2%" ]'
check "one weekly-only fetch does not switch yet (hysteresis), cache kept" '[ "$(badge 2)" = "2%" ]'
check "second weekly-only fetch: badge shows weekly 96%, logged as weekly" '[ "$(badge 3)" = "96%" ] && L | grep -q "badge title: .2%. -> .96%. (model weekly (no session window))"'
check "weekly-only fetch replaces the stale cached value" 'dump 1 | grep -q "name=Personal .* cachedBadge=96 weeklyOnly=true showsWeekly=true"'
check "no XPath session scrape once weekly-only is confirmed" '! L | awk "/QA-ACTION forecastWeekly:0:3/{on=1} /QA-ACTION inject:0:47/{on=0} on" | grep -q "falling back to XPath"'
check "activity dot follows the weekly forecast" 'bstyle 4 | grep -q "dots=\[\"gold\"\] dotViews=1"'
check "session forecast ignored while weekly-only" 'bstyle 5 | grep -q "dots=\[\"gold\"\] dotViews=1"'
check "VoiceOver says weekly, no session limit" 'nth badge 4 | grep -q "QA-BADGEA11Y .Claude usage weekly 96 percent, no session limit on this plan, rising."'
check "tooltip says weekly, no session limit" 'nth badge 4 | grep -q "QA-TOOLTIP .weekly 96% · no session limit on this plan"'
check "session window back at once: session value and session forecast" '[ "$(badge 6)" = "47%" ] && bstyle 6 | grep -q "dots=\[\"crimson\"\]"'
check "DOM weekly-only: XPath scrape first, then the weekly value" '[ "$(badge 7)" = "88%" ] && L | grep -q "(model weekly (DOM, no session window))" && L | awk "/QA-ACTION injectWeeklyDOM/{on=1} /QA-ACTION badge/{if(on)exit} on" | grep -q "falling back to XPath"'
check "two accounts: weekly-only side shows weekly %" '[ "$(badge 8)" = "P 96% | W 12%" ] && nth badge 8 | grep -q "QA-TOOLTIP .Personal: weekly 96% · no session limit on this plan"'
check "popover render of a weekly-only account written" '[ -s "$SHOTDIR/weekly-only-popover.png" ]'
check "D: no secret-looking values logged" '! grep -qiE "sessionKey=|Bearer |@[a-z0-9.-]+\.[a-z]{2,}" "$LOG"'

# ------------------------------------------------------------ scenario E
# Uses the L0/L3 QA bundle (com.local.ClaudeMeter.qa), whose own WebKit store
# holds a real claude.ai session (see qa/README.md, L3). Not cleaned up.
log "scenario E: timer fetches with the popover closed, parked page, sleep and wake"
E_APP="$OUT.e.app"
rm -rf "$E_APP"; mkdir -p "$E_APP/Contents/MacOS"
cp "$OUT" "$E_APP/Contents/MacOS/$NAME"
sed "s/$BUNDLE_ID/com.local.ClaudeMeter.qa/" "$APP/Contents/Info.plist" > "$E_APP/Contents/Info.plist"
E="wait:6,counters,wait:80,counters,dump,sleep,wait:2,dump,counters,wait:40,counters,wake,wait:10,counters,dump,done"
LOG="$LOGDIR/claudemeter.qa.multi.E.log"
RUN_EXE="$E_APP/Contents/MacOS/$NAME" RUN_EXTRA="-showMenuBarBadge YES -badgeRefreshInterval 30" run_app "$LOG" "$E"
log "log: $LOG"
cnt() { nth counters "$1" | grep "QA-COUNTERS 0 "; }
for i in 1 2 3 4 5; do log "  counters $i: $(cnt $i | sed 's/^QA-COUNTERS 0 //')"; done
J1=$(cnt 1 | num json); J2=$(cnt 2 | num json)
check "E finished" 'grep -q QA-DONE "$LOG"'
check "E: primary has a session in the QA bundle (JSON fetch at launch)" '[ "${J1:-0}" -ge 1 ]'
check "primary fetches on its timer with the popover closed (>= 2 in 80 s)" '[ $(( ${J2:-0} - ${J1:-0} )) -ge 2 ]'
check "parked: no page loaded, no page scripts, page parked" 'cnt 2 | grep -q "pageLoads=0 pageScripts=0 .* parked=true"'
check "sleep: timers stopped" 'dump 2 | grep "QA-ACCOUNT 0 " | grep -q "timerNextFire=nones" && cnt 3 | grep -q "timer=false paused=true"'
check "no fetch while asleep" '[ "$(cnt 3 | num attempts)" = "$(cnt 4 | num attempts)" ]'
check "wake: exactly one fetch, timers back" '[ $(( $(cnt 5 | num attempts) - $(cnt 4 | num attempts) )) = 1 ] && cnt 5 | grep -q "timer=true paused=false"'
check "E: paused/resumed logged" 'L | grep -q "background activity paused (sleep)" && L | grep -q "background activity resumed (sleep)"'
check "E: no secret-looking values logged" '! grep -qiE "sessionKey=|Bearer |@[a-z0-9.-]+\.[a-z]{2,}" "$LOG"'
rm -rf "$E_APP"

if [ "$KEEP" = 0 ]; then
    cleanup
    log "cleaned up $BUNDLE_ID domain and folders"
fi

if [ "$fails" -gt 0 ]; then log "FAIL: $fails check(s)"; exit 1; fi
log "PASS"
