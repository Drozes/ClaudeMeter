#!/usr/bin/env bash
# Top-level QA runner — runs every applicable layer and aggregates results.
#
# Layers:
#   L0 build.sh           — compile + smoke launch        (always)
#   L1 static-audit.sh    — grep for fragile patterns     (always)
#   L2 check-selectors    — DOM contract via jsdom        (always; needs `npm install`)
#   L3 smoke/run.sh       — launch + screenshot + OCR     (local only; needs auth)
#   L4 drift/watch.sh     — long-running, NOT run here    (install separately)
#
# Usage:
#   qa/qa.sh              # runs L0-L3 (skips L3 if --no-smoke or DISPLAY unavail)
#   qa/qa.sh --fast       # runs L0-L2 (skips smoke)
#   qa/qa.sh --layer L2   # runs only the named layer

set -uo pipefail

QA_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$QA_DIR/.." && pwd)"

MODE="full"
ONLY=""
for arg in "$@"; do
    case "$arg" in
        --fast)        MODE="fast" ;;
        --no-smoke)    MODE="fast" ;;
        --layer)       MODE="single" ;;
        L0|L1|L2|L3|L4) ONLY="$arg" ;;
        -h|--help)
            sed -n '2,16p' "$0"; exit 0 ;;
        *)
            echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

declare -a results
run_layer() {
    local name="$1" cmd="$2"
    printf '\n══ %s ══\n' "$name" >&2
    if eval "$cmd"; then
        results+=("$name PASS")
    else
        results+=("$name FAIL")
    fi
}

should_run() {
    local layer="$1"
    if [ "$MODE" = "single" ]; then [ "$ONLY" = "$layer" ]; return; fi
    return 0
}

if should_run L0; then run_layer "L0 build"          "$QA_DIR/build.sh >/dev/null"; fi
if should_run L1; then run_layer "L1 static-audit"   "$QA_DIR/static-audit.sh"; fi
if should_run L2; then
    if [ ! -d "$QA_DIR/node_modules/jsdom" ]; then
        echo "[QA] L2 needs jsdom — running 'npm install' in qa/" >&2
        ( cd "$QA_DIR" && npm install --silent --no-fund --no-audit ) || {
            echo "[QA] npm install failed" >&2
            results+=("L2 FAIL"); }
    fi
    if [ -d "$QA_DIR/node_modules/jsdom" ]; then
        run_layer "L2 dom-contract" "node $QA_DIR/check-selectors.mjs"
    fi
fi
if [ "$MODE" = "full" ] || [ "$ONLY" = "L3" ]; then
    if should_run L3; then run_layer "L3 smoke"      "$QA_DIR/smoke/run.sh"; fi
fi
if [ "$ONLY" = "L4" ]; then
    echo "[QA] L4 is long-running — invoke qa/drift/watch.sh directly" >&2
fi

# ---- aggregate verdict ----
printf '\n══ summary ══\n' >&2
fails=0
for r in "${results[@]}"; do
    printf '  %s\n' "$r" >&2
    [[ "$r" == *FAIL ]] && fails=$((fails + 1))
done

if [ "$fails" -gt 0 ]; then
    printf '\n[QA] %d layer(s) FAILED\n' "$fails" >&2
    exit 1
fi
printf '\n[QA] all layers PASS\n' >&2
