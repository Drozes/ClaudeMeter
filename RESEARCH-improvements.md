# ClaudeMeter — Top 5 Improvement Opportunities

**Date**: 2026-03-16
**Version Analyzed**: v1.7 (commit b1b0c48)
**Methodology**: Full codebase audit of architecture, code quality, CI/CD, testing, and resilience.

---

## 1. Add Unit & Integration Tests (High Impact)

**Problem**: Zero test coverage. All QA is manual, meaning regressions go undetected until a user reports them.

**What to do**:
- Add XCTest targets for the core logic that doesn't require a live WebView:
  - `UsageMeter` / `UsageSection` parsing (the XPath-based extraction at lines 69–178)
  - Cookie decryption pipeline (`ClaudeDesktopCookies` — SQLite read, PBKDF2, AES-128-CBC)
  - `AppUpdater` version comparison and code-signature verification
  - Badge-percentage formatting and freshness-timeout calculations
- Use snapshot HTML fixtures to test the scraping logic against known page structures, making it trivial to update when Anthropic changes their markup.
- Wire tests into the existing `.github/workflows/build.yml` CI so every PR is gated on passing tests.

**Expected payoff**: Catches regressions automatically, makes DOM-scraping changes safe, and enables confident refactoring.

---

## 2. Reduce DOM-Scraping Brittleness (High Impact)

**Problem**: Usage data is extracted by injecting CSS, hiding everything except usage meters, then scraping the DOM with XPath selectors that match on text content like "Current session" and "% used" (lines 69–90, 118–178). Any markup change on `claude.ai/settings/usage` silently breaks the app.

**What to do**:
- Replace text-content XPath matching with a more resilient strategy:
  - Prefer `aria-label`, `data-testid`, or semantic element queries that are less likely to change.
  - Implement a **version-pinned scraping config** (a small JSON/plist mapping selectors to data fields) so updates can ship as a config change rather than a code change.
- Add a **scraping health check**: after extraction, validate that at least one `UsageSection` was found; if not, surface a user-visible error ("Anthropic may have changed their page — check for updates") instead of showing a blank popover.
- Consider exposing a "last successful parse" timestamp in the right-click menu for debugging.

**Expected payoff**: Dramatically reduces support burden from "blank content" reports and makes recovery from Anthropic changes faster.

---

## 3. Modularize the Single-File Architecture (Medium Impact)

**Problem**: `ClaudeMeter.swift` is 1,663 lines containing the entire application — AppDelegate, UI views, cookie decryption, auto-updater, scraping logic, and timer management. While intentionally monolithic, this makes focused changes risky and code review difficult.

**What to do**:
- Extract into focused Swift files along the natural `// MARK:` boundaries that already exist:
  - `AppDelegate.swift` — lifecycle, menus, timers
  - `UsageContentView.swift` — native UI, progress bars, skeleton animation
  - `UsageScraper.swift` — JS injection, XPath parsing, data models
  - `ClaudeDesktopCookies.swift` — SQLite + Keychain + AES decryption
  - `AppUpdater.swift` — GitHub release check, download, code-sign verify
  - `Constants.swift` — centralize magic numbers (0.6s skeleton delay, 1.5s refresh wait, 2s post-load scrape delay, 3s timeout buffer, etc.)
- Keep the zero-external-dependency philosophy; this is purely internal reorganization.

**Expected payoff**: Easier code review, independent testability per module, and lower risk of accidental side-effects when touching one subsystem.

---

## 4. Fix Memory Growth in Background Polling (Medium Impact)

**Problem**: Background badge polling causes unbounded WKWebView memory growth. The current workaround (lines 742–749) force-reloads the entire page every 30 badge polls to reclaim memory, which is a blunt instrument that resets all WebView state.

**What to do**:
- Investigate replacing the background WKWebView with a lightweight `URLSession` approach:
  - Reuse the already-extracted cookies to make a direct HTTP request to the usage page.
  - Parse the HTML response server-side (in Swift) rather than rendering it in a full WebView.
  - This eliminates the DOM rendering overhead and the associated memory leak entirely.
- If the WebView must stay (e.g., for JS-dependent content), use `WKWebView.evaluateJavaScript` to null out large DOM subtrees after scraping, rather than forcing full reloads.
- Add memory-pressure monitoring (`DispatchSource.makeMemoryPressureSource`) to trigger cleanup proactively.

**Expected payoff**: Lower steady-state memory usage, no periodic reload stutter, better battery life on laptops.

---

## 5. Deduplicate Code & Extract Shared Constants (Low-Medium Impact)

**Problem**: Several patterns are duplicated or use magic numbers scattered throughout the codebase:
- The JavaScript snippet to find and click the refresh button is duplicated between `silentRefresh()` (line 711) and `badgeRefresh()` (line 753).
- Timing constants (0.6s, 1.5s, 2s, 3s) are hardcoded inline with no named references.
- Multiple `DispatchQueue.main.asyncAfter` chains could use a small scheduling helper.

**What to do**:
- Extract the shared JS refresh-button-finder into a single `static let` constant.
- Create a `Constants` enum (or extend `AppDelegate`) with named timing values:
  ```swift
  enum Timing {
      static let skeletonMinDisplay: TimeInterval = 0.6
      static let silentRefreshWait: TimeInterval = 1.5
      static let postLoadScrapeDelay: TimeInterval = 2.0
      static let freshnessBuffer: TimeInterval = 3.0
  }
  ```
- Consider a tiny `schedule(after:on:block:)` wrapper to reduce `DispatchQueue.main.asyncAfter` boilerplate.

**Expected payoff**: Single source of truth for timing behavior, easier tuning, reduced maintenance burden from duplicated code.

---

## Summary Table

| # | Improvement | Impact | Effort | Priority |
|---|------------|--------|--------|----------|
| 1 | Add unit & integration tests | High | Medium | P0 |
| 2 | Reduce DOM-scraping brittleness | High | Medium | P0 |
| 3 | Modularize single-file architecture | Medium | Medium | P1 |
| 4 | Fix memory growth in background polling | Medium | High | P1 |
| 5 | Deduplicate code & extract constants | Low-Med | Low | P2 |

---

## Additional Observations

- **No CLAUDE.md or contributing guide** — adding one would help onboard contributors.
- **App is not notarized** — users must right-click to open, which is a friction point. Apple notarization would improve first-run experience.
- **No error recovery for WebView navigation failures** — failed loads silently fail; adding `webView(_:didFail:)` delegate handling would improve resilience.
- **CI only builds; doesn't test** — once tests exist, the build workflow should gate on test passage.
