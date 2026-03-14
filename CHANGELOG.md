# ClaudeMeter — Architecture & Decisions

Quick reference for AI assistants continuing work on this project.

## Release History

### v1.5

- **Shimmer skeleton loading** — popover opens with an animated skeleton placeholder that matches the real layout, instead of a blank window
- **Minimum skeleton display** — skeleton holds for at least 0.6s so the animation is visible even on fast loads
- **Smooth content transition** — real data crossfades in with an animated popover height adjustment
- **Skeleton on every open** — loading animation shows each time the popover opens, not just on first launch

### v1.4

- **Tighter popover layout** — reduced vertical spacing throughout (edge insets, section dividers, meter gaps) to eliminate excess whitespace
- **Dynamic popover sizing** — popover height now auto-sizes to fit content instead of using a fixed 380px height
- **Dynamic Safari UA** — user agent string now derives Safari version from the host macOS version instead of being hardcoded

### v1.3

- **Badge Refresh Interval submenu** — configurable background polling for menu bar badge (30s / 1m / 2m / 5m / 10m), default 2 minutes
- **Background badge updates** — badge auto-updates in background even when popover is closed
- **Battery efficiency** — improved timer tolerance for better energy impact
- **Code signature verification** — auto-updates now verify code signatures before applying
- Various robustness and stability improvements

### v1.2

- **Auto-polling** — configurable refresh interval (6s / 20s / 30s / 60s) keeps data fresh while popover is open
- **Status dot states** — grey (stale), yellow/believed-fresh (recently updated, verifying), green (confirmed fresh)
- **Loading spinner** — tiny spinning ring around the status dot during active fetches
- **Menu bar badge** — "Show Usage in Menu Bar" toggle displays current session usage percentage next to the icon
- **Refresh Interval submenu** — right-click context menu to pick polling frequency; persisted via UserDefaults
- **NSPopoverDelegate** — polling stops automatically when popover closes

### v1.1

- Self-update system and move-to-Applications prompt
- CI release workflow

### v1.0

- Initial release: cookie import, usage display, soft reload, status dot

## Architecture

**Single file:** `ClaudeMeter.swift` — entire app, no dependencies beyond system frameworks.

### Auth — Claude Desktop cookie import (primary)

- **Proactive import at startup:** always imports cookies before loading the page (not just on login redirect)
- Reads Claude Desktop's Chromium SQLite cookie DB at `~/Library/Application Support/Claude/Cookies`
- Decrypts cookies using the "Claude Safe Storage" key from macOS Keychain via PBKDF2 + AES-128-CBC
- Encryption format: `v10` prefix (3 bytes) + IV (16 bytes) + ciphertext; plaintext has a 16-byte internal prefix to skip
- Injects decrypted `HTTPCookie` objects into WKWebView's `.default()` data store
- First run triggers a macOS Keychain permission dialog ("Always Allow" recommended)

### Auth fallback — WKWebView login window

- Full-size NSWindow with WKWebView pointed at `claude.ai/login`
- Works for email/magic-link login (Google OAuth may fail in WKWebView)
- UA spoofed to Safari to reduce Google blocks
- Real popup windows for OAuth (returns WKWebView from `createWebViewWith` instead of nil)

### Display

- Popover (400px wide, auto-height) with CSS injection to hide nav/sidebar/chrome, showing only usage meters
- Hides: site sidebar, header, "Settings" heading, settings nav tabs, "Extra usage" section, "Learn more" links, "Last updated" row, Intercom widget
- MutationObserver re-applies CSS after React re-renders
- Section headings styled as subtle uppercase labels
- Auto-resizes popover to fit content (clamped 120–500px)

### Reload behavior

- **Soft reload** (popover toggle): clicks the site's own refresh button via JS — no page navigation
- **Graceful reload** (menu Reload): fades content to 40% opacity, reloads, fades back in
- **Silent refresh** (polling timer): clicks refresh button without flashing dot grey; used for background polling
- Status dot states: grey (stale) → yellow/believed-fresh (recently updated, verifying) → green (confirmed fresh)
- Loading spinner (CSS `::after` pseudo-element) appears around dot during fetches
- `lastRefreshDate` tracked in Swift to decide between grey vs yellow on popover re-open

### Auto-polling

- `statusFreshnessInterval` (default 6s) controls poll frequency; configurable via context menu
- `Timer.scheduledTimer` fires `silentRefresh()` while popover is open
- Polling starts on popover open, stops on `popoverDidClose` (NSPopoverDelegate)
- JS-side freshness timeout = interval + 3s buffer (safety net if polling stops)

### Menu bar badge

- Scrapes "Current session" percentage from page DOM via XPath (`scrapeSessionPercentageJS`)
- Displayed as `NSStatusItem.button.title` next to the gauge icon
- Uses `monospacedDigitSystemFont` to prevent width jitter
- Updates on every refresh path: `didFinish`, `softReload`, `silentRefresh`
- Toggle persisted via `UserDefaults` (`showMenuBarBadge` key)

### Menu (right-click)

- Reload, Import from Claude Desktop, Sign In..., Refresh Interval (submenu), Show Usage in Menu Bar, Badge Refresh Interval (submenu), Check for Updates..., Quit

## Key Decisions & Findings

| Decision | Reason |
|---|---|
| Import from Claude Desktop, not Safari | WKWebView `.default()` is completely isolated from Safari's cookie store. No API to share them. |
| Chromium v10 AES-128-CBC, not AES-GCM | Tested — GCM fails with `authenticationFailure`. CBC with embedded IV + skip-16 works for all 26 cookies. |
| PBKDF2 password is the UTF-8 string from Keychain | `security -w` outputs it as base64-looking string, but it IS the literal password. Base64-decoding it produces wrong key. |
| Skip first 16 bytes of CBC plaintext | Chromium prepends a 16-byte internal prefix (possibly integrity hash) before the actual cookie value. |
| Copy DB before reading | Claude Desktop may hold a write lock on the Cookies file. Copy to `/tmp` first. |
| Import at startup, not on login redirect | Stale WKWebView cookies can prevent server redirect to `/login`, causing the reactive import to never trigger. Proactive import avoids this. |
| CSS targets structure, not class names | claude.ai uses generic Tailwind classes — no "usage" in class names. CSS must target DOM structure (`main > h1`, `section > div`, etc.) |
| UA spoofing to Safari | Google's OAuth block is server-side UA detection. Spoofing bypasses it. |
| Real popup windows for OAuth | Returning nil from `createWebViewWith` and loading inline breaks OAuth's `window.opener`/`postMessage` flow. |
| ASWebAuthenticationSession rejected | Its cookie store goes to Safari, not WKWebView. No transfer mechanism exists. |
| Silent refresh for polling | Omits grey flash (keeps dot green) during automatic refreshes — only user-initiated reloads show the loading state transition. |
| Yellow "believed-fresh" state | If `lastRefreshDate` is within the freshness interval when popover opens, shows yellow instead of grey since data is likely current. |
| XPath for DOM scraping | Anchors on stable text content ("Current session", "% used") rather than Tailwind class names which change frequently. |
| Freshness timeout = interval + 3s | Buffer accounts for the ~1.5s delay between clicking the refresh button and data arriving. |
| `variableLength` status item | Switched from `squareLength` to support showing percentage text alongside the gauge icon. `monospacedDigitSystemFont` prevents layout jitter. |
