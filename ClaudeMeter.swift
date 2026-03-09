import Cocoa
import WebKit
import Security
import SQLite3
import CommonCrypto

@main
struct ClaudeMeterApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var webView: WKWebView!
    var contextMenu: NSMenu!

    // Fallback login window (email/magic-link in WKWebView)
    var loginWindow: NSWindow?
    var loginWebView: WKWebView?

    // OAuth popup windows
    var popupWindows: [NSWindow] = []

    // Track whether we've already tried the desktop import for this launch
    var hasAttemptedDesktopImport = false

    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    static let usageURL = URL(string: "https://claude.ai/settings/usage")!
    static let loginURL = URL(string: "https://claude.ai/login")!

    static let usageCSS = """
        /* Hide outer shell: sidebar, header, footer */
        body > div > div.root > div > div:first-child,
        header, aside, footer,
        [data-testid="sidebar"], [data-testid="nav"],
        [class*="sidebar"], [class*="Sidebar"] {
            display: none !important;
        }
        html, body {
            background: #1a1a1a !important;
            margin: 0 !important;
            padding: 0 !important;
            overflow-x: hidden !important;
        }
        /* Hide the "Settings" heading and settings nav tabs */
        main > h1 {
            display: none !important;
        }
        main > div > nav {
            display: none !important;
        }
        /* Make the settings content grid single-column (no nav sidebar) */
        main > div {
            display: block !important;
        }
        main {
            padding: 10px 14px !important;
            margin: 0 !important;
            max-width: 100% !important;
            width: 100% !important;
            box-sizing: border-box !important;
        }
        /* Hide "Extra usage" section */
        [data-testid="extra-usage-section"] {
            display: none !important;
        }
        /* Hide "Plan usage limits" heading, "Learn more" link, and "Last updated" row */
        section > div:first-child:has(h2) h2:first-of-type {
            display: none !important;
        }
        section a[href*="understanding-usage"] {
            display: none !important;
        }
        section > div:last-child:has(button):has(p) {
            display: none !important;
        }
        /* Clean spacing */
        section {
            gap: 0.75rem !important;
            margin-bottom: 0 !important;
            padding-bottom: 0.75rem !important;
            border-bottom: none !important;
        }
        section h2 {
            font-size: 0.8rem !important;
            text-transform: uppercase !important;
            letter-spacing: 0.05em !important;
            color: #999 !important;
            margin-bottom: 0 !important;
        }
        section .gap-6 {
            gap: 0.75rem !important;
        }
        section .mb-8 {
            margin-bottom: 0.5rem !important;
        }
        section .pb-8 {
            padding-bottom: 0.5rem !important;
        }
        section .space-y-6 > * + * {
            margin-top: 0.75rem !important;
        }
        /* Progress bar rows */
        section .gap-y-3 {
            gap: 0.25rem !important;
        }
        section .gap-1\\.5 {
            gap: 0.1rem !important;
        }
        /* Divider line */
        section .h-px {
            margin: 0.5rem 0 !important;
        }
        /* Hide overlays */
        [class*="modal"], [class*="Modal"],
        [class*="banner"], [class*="Banner"],
        [class*="cookie"], [class*="Cookie"],
        [class*="toast"], [class*="Toast"],
        .intercom-lightweight-app,
        #intercom-frame {
            display: none !important;
        }
        ::-webkit-scrollbar { display: none !important; }
        /* Status dot */
        #claude-status-dot {
            position: fixed;
            top: 8px;
            right: 8px;
            width: 8px;
            height: 8px;
            border-radius: 50%;
            background: #666;
            z-index: 99999;
            transition: background 0.3s ease;
            box-shadow: 0 0 3px rgba(0,0,0,0.4);
        }
        #claude-status-dot.fresh {
            background: #34d399;
            box-shadow: 0 0 6px rgba(52,211,153,0.5);
        }
    """

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "Claude Usage")
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        setupMenu()
        setupPopover()
    }

    // MARK: - Popover

    func setupPopover() {
        let cssInjection = WKUserScript(
            source: """
                var style = document.createElement('style');
                style.id = 'claude-usage-style';
                style.textContent = `\(Self.usageCSS)`;
                document.head.appendChild(style);
                if (!document.querySelector('#claude-status-dot')) {
                    var dot = document.createElement('div');
                    dot.id = 'claude-status-dot';
                    document.body.appendChild(dot);
                }
                var observer = new MutationObserver(function() {
                    if (!document.querySelector('#claude-usage-style')) {
                        var s = document.createElement('style');
                        s.id = 'claude-usage-style';
                        s.textContent = `\(Self.usageCSS)`;
                        document.head.appendChild(s);
                    }
                    if (!document.querySelector('#claude-status-dot')) {
                        var d = document.createElement('div');
                        d.id = 'claude-status-dot';
                        document.body.appendChild(d);
                    }
                });
                observer.observe(document.body, { childList: true, subtree: true });
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(cssInjection)
        config.websiteDataStore = .default()

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 380), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = Self.safariUA

        // Always import fresh cookies from Claude Desktop before loading
        hasAttemptedDesktopImport = true
        importFromClaudeDesktop { [weak self] success in
            guard let self = self else { return }
            self.webView.load(URLRequest(url: Self.usageURL))
        }

        let vc = NSViewController()
        vc.view = webView
        vc.view.frame = NSRect(x: 0, y: 0, width: 400, height: 380)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 380)
        popover.behavior = .transient
        popover.contentViewController = vc
    }

    // MARK: - Claude Desktop Cookie Import

    @objc func importFromDesktop() {
        importFromClaudeDesktop { [weak self] success in
            guard let self = self else { return }
            if success {
                self.webView.load(URLRequest(url: Self.usageURL))
            } else {
                let alert = NSAlert()
                alert.messageText = "Could not import session"
                alert.informativeText = "Make sure Claude Desktop is installed and you're signed in.\n\nAlternatively, use \"Sign In\u{2026}\" to log in with email."
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    func importFromClaudeDesktop(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let cookies = ClaudeDesktopCookies.extract()
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let cookies = cookies, !cookies.isEmpty else {
                    completion(false)
                    return
                }
                self.injectCookies(cookies) { completion(true) }
            }
        }
    }

    func injectCookies(_ cookies: [HTTPCookie], completion: @escaping () -> Void) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    // MARK: - Fallback Login Window (email/magic-link)

    func showLoginWindow() {
        if let window = loginWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Claude"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let loginConfig = WKWebViewConfiguration()
        loginConfig.websiteDataStore = .default()

        let lw = WKWebView(frame: window.contentView!.bounds, configuration: loginConfig)
        lw.autoresizingMask = [.width, .height]
        lw.navigationDelegate = self
        lw.uiDelegate = self
        lw.customUserAgent = Self.safariUA
        lw.load(URLRequest(url: Self.loginURL))

        window.contentView?.addSubview(lw)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        loginWebView = lw
        loginWindow = window
    }

    func closeLoginWindow() {
        loginWindow?.close()
        loginWindow = nil
        loginWebView = nil
        webView.load(URLRequest(url: Self.usageURL))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString else { return }

        // Popover hit a login page → show login window (desktop import already attempted at startup)
        if webView === self.webView && isLoginURL(url) {
            if !hasAttemptedDesktopImport {
                hasAttemptedDesktopImport = true
                importFromClaudeDesktop { [weak self] success in
                    guard let self = self else { return }
                    if success {
                        self.webView.load(URLRequest(url: Self.usageURL))
                    } else {
                        if self.popover.isShown { self.popover.performClose(nil) }
                        self.showLoginWindow()
                    }
                }
                return
            }
            if popover.isShown { popover.performClose(nil) }
            showLoginWindow()
            return
        }

        // Login WebView reached a non-login page → auth succeeded
        if webView === loginWebView && url.contains("claude.ai") && !isLoginURL(url) {
            closeLoginWindow()
            return
        }

        if webView === self.webView {
            // Fade back in after reload and mark status dot green
            webView.evaluateJavaScript("""
                document.body.style.transition='opacity 0.2s';
                document.body.style.opacity='1';
                var dot = document.querySelector('#claude-status-dot');
                if (dot) dot.className = 'fresh';
            """, completionHandler: nil)
            popover.contentSize = url.contains("/settings/usage")
                ? NSSize(width: 400, height: 380)
                : NSSize(width: 420, height: 600)
        }
    }

    // MARK: - WKUIDelegate (popup handling for OAuth)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        popupWindow.title = "Sign In"
        popupWindow.center()
        popupWindow.isReleasedWhenClosed = false

        let popupWebView = WKWebView(frame: popupWindow.contentView!.bounds, configuration: configuration)
        popupWebView.autoresizingMask = [.width, .height]
        popupWebView.navigationDelegate = self
        popupWebView.uiDelegate = self
        popupWebView.customUserAgent = Self.safariUA

        popupWindow.contentView?.addSubview(popupWebView)
        popupWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        popupWindows.append(popupWindow)
        return popupWebView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let window = webView.window else { return }
        window.close()
        popupWindows.removeAll { $0 === window }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === loginWindow {
            loginWindow = nil
            loginWebView = nil
            webView.load(URLRequest(url: Self.usageURL))
        }
        popupWindows.removeAll { $0 === window }
    }

    // MARK: - Menu

    func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Reload", action: #selector(reload), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Import from Claude Desktop", action: #selector(importFromDesktop), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: "Sign In\u{2026}", action: #selector(openLogin), keyEquivalent: "l"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ClaudeMeter", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = nil
        contextMenu = menu
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent

        if event?.type == .rightMouseUp {
            statusItem.menu = contextMenu
            statusItem.button?.performClick(nil)
            DispatchQueue.main.async { self.statusItem.menu = nil }
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            softReload()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Soft reload: if already on the usage page, click the site's own refresh button.
    /// Falls back to a graceful full page reload if needed.
    func softReload() {
        guard let url = webView.url?.absoluteString, url.contains("/settings/usage") else {
            gracefulReload()
            return
        }
        // Set dot grey while refreshing, click the site's refresh button, then set dot green
        let js = """
        (function() {
            var dot = document.querySelector('#claude-status-dot');
            if (dot) dot.className = '';
            var btns = document.querySelectorAll('button');
            for (var b of btns) {
                if (b.querySelector('svg') && b.closest('[class*="justify-between"]') &&
                    b.closest('[class*="text-xs"]')) {
                    b.click();
                    setTimeout(function() {
                        if (dot) dot.className = 'fresh';
                    }, 1500);
                    return 'clicked';
                }
            }
            return 'not_found';
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            if (result as? String) != "clicked" {
                self?.gracefulReload()
            }
        }
    }

    /// Full reload with fade transition to avoid white flash.
    func gracefulReload() {
        webView.evaluateJavaScript("""
            document.body.style.transition='opacity 0.15s';
            document.body.style.opacity='0.4';
            var dot = document.querySelector('#claude-status-dot');
            if (dot) dot.className = '';
        """, completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.webView.load(URLRequest(url: Self.usageURL))
        }
    }

    @objc func reload() { gracefulReload() }
    @objc func openLogin() { showLoginWindow() }
    @objc func quit() { NSApp.terminate(nil) }

    private func isLoginURL(_ url: String) -> Bool {
        url.contains("/login") || url.contains("/signin") || url.contains("accounts.google.com")
    }
}

// MARK: - Claude Desktop Cookie Extraction
// Reads cookies from Claude Desktop's Chromium SQLite DB, decrypts them using
// the "Claude Safe Storage" key from the macOS Keychain, and returns HTTPCookies.

enum ClaudeDesktopCookies {
    private static let dbPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/Cookies").path
    private static let keychainService = "Claude Safe Storage"
    private static let keychainAccount = "Claude Key"

    static func extract() -> [HTTPCookie]? {
        // 1. Get encryption key from Keychain
        guard let password = keychainPassword(),
              let aesKey = deriveKey(password: password) else { return nil }

        // 2. Copy the DB (Claude Desktop may have it locked)
        let tmpPath = NSTemporaryDirectory() + "claude_cookies_\(ProcessInfo.processInfo.processIdentifier).db"
        try? FileManager.default.removeItem(atPath: tmpPath)
        guard (try? FileManager.default.copyItem(atPath: dbPath, toPath: tmpPath)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // 3. Read and decrypt cookies
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT host_key, name, path, encrypted_value, expires_utc, is_secure, is_httponly
            FROM cookies WHERE host_key LIKE '%claude.ai%' OR host_key LIKE '%claude.com%'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var cookies: [HTTPCookie] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let host     = String(cString: sqlite3_column_text(stmt, 0))
            let name     = String(cString: sqlite3_column_text(stmt, 1))
            let path     = String(cString: sqlite3_column_text(stmt, 2))
            let isSecure = sqlite3_column_int(stmt, 5) != 0
            let isHttp   = sqlite3_column_int(stmt, 6) != 0

            // Decrypt the encrypted_value
            guard let encPtr = sqlite3_column_blob(stmt, 3) else { continue }
            let encLen = Int(sqlite3_column_bytes(stmt, 3))
            guard encLen > 0 else { continue }
            let encData = Data(bytes: encPtr, count: encLen)

            guard let value = decrypt(encData, key: aesKey), !value.isEmpty else { continue }

            // Chromium stores expiry as microseconds since 1601-01-01
            let expiresUtc = sqlite3_column_int64(stmt, 4)
            let unixSec = (expiresUtc - 11644473600000000) / 1000000
            let expiryDate = expiresUtc > 0
                ? Date(timeIntervalSince1970: TimeInterval(unixSec))
                : Date(timeIntervalSinceNow: 86400 * 365)

            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: host, .path: path, .name: name, .value: value, .expires: expiryDate,
            ]
            if isSecure { props[.secure] = "TRUE" }
            if isHttp   { props[.init("HttpOnly")] = "TRUE" }

            if let cookie = HTTPCookie(properties: props) {
                cookies.append(cookie)
            }
        }
        return cookies.isEmpty ? nil : cookies
    }

    // MARK: - Keychain

    private static func keychainPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String:  keychainService,
            kSecAttrAccount as String:  keychainAccount,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return password
    }

    // MARK: - Key Derivation (PBKDF2)

    private static func deriveKey(password: String) -> [UInt8]? {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: 16)
        let rc = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.utf8.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003, &key, 16
        )
        return rc == kCCSuccess ? key : nil
    }

    // MARK: - Cookie Decryption (AES-128-CBC)
    // Format: "v10" (3 bytes) + IV (16 bytes) + ciphertext
    // Plaintext: 16-byte internal prefix + actual cookie value

    private static func decrypt(_ data: Data, key: [UInt8]) -> String? {
        guard data.count > 19,
              data[0] == 0x76, data[1] == 0x31, data[2] == 0x30 // "v10"
        else { return nil }

        let iv = [UInt8](data[3..<19])
        let ct = [UInt8](data[19...])
        var plain = [UInt8](repeating: 0, count: ct.count + 16)
        var plainLen = 0

        let rc = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionPKCS7Padding),
            key, 16, iv, ct, ct.count,
            &plain, plain.count, &plainLen
        )
        // Skip 16-byte internal prefix that Chromium prepends
        guard rc == kCCSuccess, plainLen > 16 else { return nil }
        return String(bytes: plain[16..<plainLen], encoding: .utf8)
    }
}
