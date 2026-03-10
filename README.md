# ClaudeMeter

A lightweight macOS menu bar app that shows your Claude.ai usage at a glance — session limits, weekly limits, and progress bars in a compact popover.

Authenticates automatically by importing your session from the Claude Desktop app.

## Features

- **One-click usage** — click the menu bar icon to see current session and weekly usage
- **Menu bar badge** — optionally show your session usage percentage right in the menu bar
- **Auto-refresh** — configurable polling interval (6s / 20s / 30s / 60s) keeps data fresh while the popover is open
- **Status indicator** — green dot (fresh), yellow dot (believed fresh, verifying), grey dot (stale), with a spinning loader during fetches
- **Auto-auth** — imports cookies from Claude Desktop on launch, no manual login needed
- **Soft reload** — re-opening the popover refreshes data in-place without a full page load
- **Fallback login** — right-click → "Sign In..." for email/magic-link if Claude Desktop isn't available

## Peak In
 
![Screen Recording 2026-03-09 at 9 00 49 PM](https://github.com/user-attachments/assets/cf286856-5352-4258-87bd-55da17294860)



## Requirements

- macOS 13+ (Ventura or later)
- Claude Desktop installed and signed in

## Install

1. Download **ClaudeMeter.zip** from the [latest release](https://github.com/Drozes/ClaudeMeter/releases/latest)
2. Unzip the archive
3. **Right-click** ClaudeMeter.app → **Open** (required on first launch since the app isn't notarized)
4. On first launch, the app will offer to move itself to your Applications folder

> **Note:** Double-clicking will show "Apple could not verify" — this is normal for community-distributed apps. Right-click → Open bypasses this. You only need to do this once.

macOS will show a Keychain access dialog on first run — click **Always Allow**.

To update later, right-click the menu bar icon → **Check for Updates…**

### Build from Source

If you prefer to build it yourself:

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

Or open `ClaudeMeter.xcodeproj` in Xcode and hit **⌘R** for a proper `.app` bundle.

## Usage

| Action | How |
|---|---|
| View usage | Left-click the menu bar icon |
| Refresh data | Close and re-open the popover, or right-click → Reload |
| Show usage badge | Right-click → Show Usage in Menu Bar |
| Change refresh interval | Right-click → Refresh Interval → pick 6s / 20s / 30s / 60s |
| Re-import cookies | Right-click → Import from Claude Desktop |
| Manual login | Right-click → Sign In... |
| Check for updates | Right-click → Check for Updates… |
| Quit | Right-click → Quit |

## How It Works

The app is a single Swift file (`ClaudeMeter.swift`) with no dependencies beyond system frameworks.

1. **Cookie import** — Reads Claude Desktop's Chromium cookie database (`~/Library/Application Support/Claude/Cookies`), decrypts cookies via the macOS Keychain, and injects them into a WKWebView
2. **Usage page** — Loads `claude.ai/settings/usage` in the WKWebView
3. **CSS injection** — Hides all site chrome (sidebar, nav, headers, overlays), leaving only the usage meters
4. **Soft reload** — On re-open, clicks the site's own refresh button via JavaScript instead of doing a full page load
5. **Auto-polling** — While the popover is open, a timer triggers silent refreshes at the configured interval to keep data current
6. **Badge scraping** — Extracts the session usage percentage from the page DOM via XPath and displays it in the menu bar

## Troubleshooting

**"Apple could not verify"** — Right-click the app → Open. Alternatively, go to System Settings → Privacy & Security, scroll down, and click "Open Anyway".

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
