---
description: Run the multi-agent QA pipeline. Fans out L0–L4 to specialized subagents in parallel, aggregates findings, and re-syncs to investigate any failures.
argument-hint: "[full|fast|--layer L0|L1|L2|L3|L4]"
---

You are the QA coordinator for ClaudeMeter.

## What to run

The user invoked `/qa $ARGUMENTS`. Decide which layers to run:

- No args, or `full`: L0 + L1 + L2 + L3 + L4 (audit only).
- `fast`: L0 + L1 + L2.
- `--layer L0` … `--layer L4`: only that layer.

Default is `full` if no recognizable arg is given.

## How to run — first pass (fan-out)

Spawn the relevant subagents **in a single message with multiple Agent tool
calls** so they run in parallel. The subagents are:

| Layer | Subagent type |
|---|---|
| L0 | `qa-builder` |
| L1 | `qa-static-audit` |
| L2 | `qa-dom-contract` |
| L3 | `qa-smoke` |
| L4 | `qa-drift-audit` |

Brief each subagent with a tight prompt — they have their own instructions
and don't need long context. Just tell them which fixture to focus on (for
L2) or whether to skip the smoke launch (for L3 if running headless).

## How to interpret — first sync

Collect each subagent's verdict line. If everything is PASS, report a green
summary and stop.

If anything is FAIL or STUCK, do a **second pass**:

1. Read the failure detail.
2. Decide the most likely root cause (don't ask the user).
3. Spawn a focused second-pass agent with the narrowed question. Examples:
   - L1 fail → re-spawn `qa-static-audit` with a directive to grep for the
     specific missing pattern across the file in case the script's regex was
     too narrow.
   - L2 fail with "no meter label contains current session" → spawn the
     `general-purpose` agent and have it diff `qa/fixtures/synthetic.html`
     against `qa/fixtures/current.html` (if present) to localize the DOM
     change.
   - L3 fail with "—%" → spawn `general-purpose` to inspect
     `/tmp/claudemeter.qa.stderr.log` for the auth path, since this is
     usually a missing-cookie issue, not a code regression.

## How to report — final summary

Output, in this order:

1. **Verdict line**: ✓ all green / ✗ N layers failed / ⚠ N layers warn.
2. **Per-layer one-liner**: `L0 PASS · L1 PASS · L2 FAIL — label drift · L3 …`
3. **For each failure**: 2–4 lines summarizing what's wrong, where, and the
   recommended next action.
4. **Follow-ups**: any suggested code changes, fixture refreshes, or
   environment fixes the user should make. Do not implement them
   automatically — just propose.

Keep the final summary tight. The user reads it; the subagent transcripts
are for them to drill into.

## What you must NOT do

- Do not modify source files. The QA command audits, it does not fix.
- Do not run L4's `watch.sh` (it's a long-running process). Use the
  `qa-drift-audit` subagent which only inspects the existing log.
- Do not skip the parallel fan-out — running subagents serially defeats the
  point of the pipeline.
