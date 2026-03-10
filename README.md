# ClaudeMeter

A lightweight macOS menu bar app that shows your Claude.ai usage at a glance — session limits, weekly limits, and progress bars in a compact popover.

Authenticates automatically by importing your session from the Claude Desktop app.

## Features

- **One-click usage** — click the menu bar icon to see current session and weekly usage
- **Auto-auth** — imports cookies from Claude Desktop on launch, no manual login needed
- **Soft reload** — re-opening the popover refreshes data in-place without a full page load
- **Status indicator** — green dot confirms data is fresh; grey means loading
- **Fallback login** — right-click → "Sign In..." for email/magic-link if Claude Desktop isn't available

## Peak In
 
![Screen Recording 2026-03-09 at 9 00 49 PM](https://github.com/user-attachments/assets/cf286856-5352-4258-87bd-55da17294860)




## Requirements

- macOS 13+ (Ventura or later)
- Claude Desktop installed and signed in
- Xcode Command Line Tools (for building)

## Build & Run

```bash
swiftc ClaudeMeter.swift \
  -framework Cocoa \
  -framework WebKit \
  -framework Security \
  -lsqlite3 \
  -parse-as-library \
  -o ClaudeMeter

./ClaudeMeter
```

On first launch, macOS will show a Keychain access dialog — click **Always Allow**.

### Xcode

Open `ClaudeMeter.xcodeproj` and hit **⌘R**. This produces a proper `.app` bundle suitable for Login Items.

## Usage

| Action | How |
|---|---|
| View usage | Left-click the menu bar icon |
| Refresh data | Close and re-open the popover, or right-click → Reload |
| Re-import cookies | Right-click → Import from Claude Desktop |
| Manual login | Right-click → Sign In... |
| Quit | Right-click → Quit |

## How It Works

The app is a single Swift file (`ClaudeMeter.swift`) with no dependencies beyond system frameworks.

1. **Cookie import** — Reads Claude Desktop's Chromium cookie database (`~/Library/Application Support/Claude/Cookies`), decrypts cookies via the macOS Keychain, and injects them into a WKWebView
2. **Usage page** — Loads `claude.ai/settings/usage` in the WKWebView
3. **CSS injection** — Hides all site chrome (sidebar, nav, headers, overlays), leaving only the usage meters
4. **Soft reload** — On re-open, clicks the site's own refresh button via JavaScript instead of doing a full page load

## Troubleshooting

**Keychain dialog keeps appearing** — Click "Always Allow" instead of "Allow".

**"Could not import session"** — Make sure Claude Desktop is installed and signed in.

**Blank or wrong content** — Anthropic may have changed their page markup. Adjust the `usageCSS` selectors in `ClaudeMeter.swift`.

**Fresh start:**
```bash
rm -rf ~/Library/WebKit/com.local.ClaudeMeter/
rm -rf ~/Library/Caches/com.local.ClaudeMeter/
rm -f  ~/Library/HTTPStorages/com.local.ClaudeMeter.binarycookies
```

## License

MIT
