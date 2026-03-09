# ClaudeMeter — Architecture & Decisions

Quick reference for AI assistants continuing work on this project.

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

- Popover (400x380) with CSS injection to hide nav/sidebar/chrome, showing only usage meters
- Hides: site sidebar, header, "Settings" heading, settings nav tabs, "Extra usage" section, "Learn more" links, "Last updated" row, Intercom widget
- MutationObserver re-applies CSS after React re-renders
- Section headings styled as subtle uppercase labels
- Auto-resizes popover (380px for usage, 600px for other pages)

### Reload behavior

- **Soft reload** (popover toggle): clicks the site's own refresh button via JS — no page navigation
- **Graceful reload** (menu Reload): fades content to 40% opacity, reloads, fades back in
- Status dot: grey while loading, green with glow when data confirmed fresh

### Menu (right-click)

- Reload, Import from Claude Desktop, Sign In..., Quit

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
