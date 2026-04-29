# QA fixtures

Static HTML snapshots of `claude.ai/settings/usage` used by the **L2 DOM-contract
validator** ([`../check-selectors.mjs`](../check-selectors.mjs)) to assert the
in-app JS scrapers (`scrapeUsageJS`, `scrapeSessionPercentageJS`) still match the
page structure they were written for.

## Fixtures present

- `synthetic.html` + `synthetic.expected.json` — hand-crafted DOM that mirrors
  the structural shape claude.ai uses, plus a deliberately tricky card whose
  leaf-text order would have broken the pre-fix label picker. Keeps the
  validator runnable on any machine without auth.

## Capturing a fresh real-page fixture

The synthetic fixture catches structural regressions but not subtle layout
changes Anthropic ships on the live page. To capture a real fixture:

1. Open Chrome (or any Chromium) and sign in to claude.ai.
2. Navigate to `https://claude.ai/settings/usage`. Wait for the meters to render.
3. Open DevTools (Cmd-Opt-I), go to **Elements**, right-click the
   `<html>` node, **Copy → Copy outerHTML**.
4. Paste into `qa/fixtures/current.html`.
5. Hand-write `qa/fixtures/current.expected.json` describing what the validator
   should see (use `synthetic.expected.json` as a template, replace percentages
   with what you observed on the live page).
6. Run `node qa/check-selectors.mjs current` to verify.

Re-capture whenever the validator starts failing on a real fixture but passing
on the synthetic one — that's the signal Anthropic shipped a layout change.

> Real fixtures may contain UI text tied to your account (plan tier, reset
> timestamps). They are **not committed** by default — `qa/fixtures/current*`
> is git-ignored. Treat them as local-only snapshots.
