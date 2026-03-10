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

class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var webView: WKWebView!
    var contextMenu: NSMenu!

    // How often (seconds) to poll for fresh data while the popover is open.
    // The status dot stays green as long as data was refreshed within this window.
    static let refreshIntervalKey = "refreshInterval"
    static let refreshIntervalOptions: [(label: String, seconds: TimeInterval)] = [
        ("6 seconds", 6), ("20 seconds", 20), ("30 seconds", 30), ("60 seconds", 60)
    ]
    var statusFreshnessInterval: TimeInterval = {
        let saved = UserDefaults.standard.double(forKey: AppDelegate.refreshIntervalKey)
        return saved > 0 ? saved : 6.0
    }()
    var refreshTimer: Timer?
    var lastRefreshDate: Date?

    // Menu bar badge
    static let showBadgeKey = "showMenuBarBadge"
    var showMenuBarBadge: Bool = UserDefaults.standard.bool(forKey: AppDelegate.showBadgeKey) {
        didSet {
            UserDefaults.standard.set(showMenuBarBadge, forKey: Self.showBadgeKey)
            applyBadgeVisibility()
        }
    }

    /// JS to scrape the "Current session" usage percentage from the page.
    static let scrapeSessionPercentageJS = """
    (function() {
        try {
            var snap = document.evaluate(
                "//text()[contains(., 'Current session')]",
                document.body, null,
                XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null
            );
            if (snap.snapshotLength > 0) {
                var node = snap.snapshotItem(0);
                var el = node.parentElement;
                for (var i = 0; i < 6 && el; i++) {
                    var t = el.textContent;
                    if (t.indexOf('Current session') !== -1 && /\\d+%\\s*used/.test(t)) {
                        var m = t.match(/(\\d+)%\\s*used/);
                        if (m) return parseInt(m[1], 10);
                    }
                    el = el.parentElement;
                }
            }
        } catch(e) {}
        return null;
    })()
    """

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
            transition: background 0.3s ease, opacity 0.3s ease, box-shadow 0.3s ease;
            box-shadow: 0 0 3px rgba(0,0,0,0.4);
        }
        #claude-status-dot.believed-fresh {
            background: #d4a843;
            opacity: 0.6;
            box-shadow: 0 0 4px rgba(212,168,67,0.4);
        }
        #claude-status-dot.fresh {
            background: #34d399;
            opacity: 1;
            box-shadow: 0 0 6px rgba(52,211,153,0.5);
        }
        #claude-status-dot.loading::after {
            content: '';
            position: absolute;
            top: -3px;
            left: -3px;
            width: 14px;
            height: 14px;
            border-radius: 50%;
            border: 1.5px solid transparent;
            border-top-color: #888;
            animation: dot-spin 0.8s linear infinite;
        }
        #claude-status-dot.believed-fresh.loading::after {
            border-top-color: #d4a843;
        }
        #claude-status-dot.fresh.loading::after {
            border-top-color: #34d399;
        }
        @keyframes dot-spin {
            to { transform: rotate(360deg); }
        }
    """

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "Claude Usage")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        applyBadgeVisibility()

        setupMenu()
        setupPopover()

        // Prompt to move to /Applications if not already there
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AppUpdater.promptMoveToApplicationsIfNeeded()
        }
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
                window.__claudeStatusTimeout = null;
                window.__statusFreshnessMs = \(Int(statusFreshnessInterval * 1000 + 3000));
                window.__setStatusFresh = function() {
                    var dot = document.querySelector('#claude-status-dot');
                    if (dot) {
                        dot.classList.add('fresh');
                        dot.classList.remove('loading', 'believed-fresh');
                        if (window.__claudeStatusTimeout) clearTimeout(window.__claudeStatusTimeout);
                        window.__claudeStatusTimeout = setTimeout(function() {
                            dot.classList.remove('fresh');
                        }, window.__statusFreshnessMs);
                    }
                };
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
        popover.delegate = self
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
            lastRefreshDate = Date()
            webView.evaluateJavaScript("""
                document.body.style.transition='opacity 0.2s';
                document.body.style.opacity='1';
                if (window.__setStatusFresh) window.__setStatusFresh();
            """, completionHandler: nil)
            popover.contentSize = url.contains("/settings/usage")
                ? NSSize(width: 400, height: 380)
                : NSSize(width: 420, height: 600)
            updateMenuBarBadge()
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

        let intervalItem = NSMenuItem(title: "Refresh Interval", action: nil, keyEquivalent: "")
        let intervalSubmenu = NSMenu()
        for option in Self.refreshIntervalOptions {
            let item = NSMenuItem(title: option.label, action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
            item.tag = Int(option.seconds)
            item.target = self
            if option.seconds == statusFreshnessInterval {
                item.state = .on
            }
            intervalSubmenu.addItem(item)
        }
        intervalItem.submenu = intervalSubmenu
        menu.addItem(intervalItem)

        let badgeItem = NSMenuItem(title: "Show Usage in Menu Bar", action: #selector(toggleBadge(_:)), keyEquivalent: "b")
        badgeItem.target = self
        badgeItem.state = showMenuBarBadge ? .on : .off
        menu.addItem(badgeItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(checkForUpdates), keyEquivalent: "u"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ClaudeMeter", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = nil
        contextMenu = menu
    }

    @objc func toggleBadge(_ sender: NSMenuItem) {
        showMenuBarBadge.toggle()
        sender.state = showMenuBarBadge ? .on : .off
    }

    @objc func setRefreshInterval(_ sender: NSMenuItem) {
        let seconds = TimeInterval(sender.tag)
        statusFreshnessInterval = seconds
        UserDefaults.standard.set(seconds, forKey: Self.refreshIntervalKey)

        // Update checkmarks
        if let submenu = sender.menu {
            for item in submenu.items { item.state = .off }
        }
        sender.state = .on

        // Update the JS-side freshness timeout
        let freshnessMs = Int(seconds * 1000 + 3000)
        webView.evaluateJavaScript("window.__statusFreshnessMs = \(freshnessMs);", completionHandler: nil)

        // Restart polling if active
        if refreshTimer != nil {
            startPolling()
        }
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
            startPolling()
        }
    }

    /// Soft reload: if already on the usage page, click the site's own refresh button.
    /// Falls back to a graceful full page reload if needed.
    func softReload() {
        guard let url = webView.url?.absoluteString, url.contains("/settings/usage") else {
            gracefulReload()
            return
        }
        let believedFresh = lastRefreshDate.map { -$0.timeIntervalSinceNow < statusFreshnessInterval } ?? false
        let dotClass = believedFresh ? "believed-fresh loading" : "loading"
        // Set dot to believed-fresh (yellow) or grey + loading spinner, then refresh
        let js = """
        (function() {
            var dot = document.querySelector('#claude-status-dot');
            if (dot) { dot.className = '\(dotClass)'; }
            var btns = document.querySelectorAll('button');
            for (var b of btns) {
                if (b.querySelector('svg') && b.closest('[class*="justify-between"]') &&
                    b.closest('[class*="text-xs"]')) {
                    b.click();
                    setTimeout(function() {
                        if (window.__setStatusFresh) window.__setStatusFresh();
                    }, 1500);
                    return 'clicked';
                }
            }
            return 'not_found';
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            if (result as? String) == "clicked" {
                // Data arrives ~1.5s after click; mark refresh time and update badge
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.lastRefreshDate = Date()
                    self?.updateMenuBarBadge()
                }
            } else {
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
            if (dot) { dot.classList.remove('fresh'); dot.classList.add('loading'); }
        """, completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.webView.load(URLRequest(url: Self.usageURL))
        }
    }

    @objc func reload() { gracefulReload() }
    @objc func openLogin() { showLoginWindow() }
    @objc func checkForUpdates() { AppUpdater.checkForUpdates() }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: - Polling

    func startPolling() {
        refreshTimer?.invalidate()
        NSLog("[ClaudeMeter] startPolling: interval=\(statusFreshnessInterval)s")
        refreshTimer = Timer.scheduledTimer(withTimeInterval: statusFreshnessInterval, repeats: true) { [weak self] _ in
            NSLog("[ClaudeMeter] timer fired, calling silentRefresh")
            self?.silentRefresh()
        }
    }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Silent refresh: keeps the dot green and clicks the site's refresh button.
    /// The dot is set fresh immediately (we're actively polling), then we also
    /// attempt to refresh the underlying data via the site's own button.
    func silentRefresh() {
        guard popover.isShown,
              let url = webView.url?.absoluteString, url.contains("/settings/usage") else { return }
        let js = """
        (function() {
            var dot = document.querySelector('#claude-status-dot');
            if (dot) dot.classList.add('loading');
            var btns = document.querySelectorAll('button');
            for (var b of btns) {
                if (b.querySelector('svg') && b.closest('[class*="justify-between"]') &&
                    b.closest('[class*="text-xs"]')) {
                    b.click();
                    setTimeout(function() {
                        if (window.__setStatusFresh) window.__setStatusFresh();
                    }, 1500);
                    return 'clicked';
                }
            }
            if (window.__setStatusFresh) window.__setStatusFresh();
            return 'not_found';
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            if let error = error {
                NSLog("[ClaudeMeter] silentRefresh JS error: \(error.localizedDescription)")
            } else {
                NSLog("[ClaudeMeter] silentRefresh result: \(result ?? "nil")")
                if (result as? String) == "clicked" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self?.lastRefreshDate = Date()
                        self?.updateMenuBarBadge()
                    }
                } else {
                    // Button not found but we called __setStatusFresh
                    self?.lastRefreshDate = Date()
                    self?.updateMenuBarBadge()
                }
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        NSLog("[ClaudeMeter] popoverDidClose, stopping polling")
        stopPolling()
    }

    // MARK: - Menu Bar Badge

    func applyBadgeVisibility() {
        guard let button = statusItem.button else { return }
        if showMenuBarBadge {
            button.imagePosition = .imageLeading
            // Scrape now if we have data
            updateMenuBarBadge()
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    func updateMenuBarBadge() {
        guard showMenuBarBadge, webView != nil else { return }
        webView.evaluateJavaScript(Self.scrapeSessionPercentageJS) { [weak self] result, _ in
            guard let self = self, let percentage = result as? Int else { return }
            self.statusItem.button?.title = "\(percentage)%"
        }
    }

    private func isLoginURL(_ url: String) -> Bool {
        url.contains("/login") || url.contains("/signin") || url.contains("accounts.google.com")
    }
}

// MARK: - App Updates & Installation

enum AppUpdater {
    private static let githubRepo = "Drozes/ClaudeMeter"

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    static var isAppBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isRunningFromApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") ||
               path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    // MARK: - Move to Applications

    static func promptMoveToApplicationsIfNeeded() {
        guard isAppBundle, !isRunningFromApplications else { return }
        guard !UserDefaults.standard.bool(forKey: "declinedMoveToApplications") else { return }

        let alert = NSAlert()
        alert.messageText = "Move to Applications?"
        alert.informativeText = "ClaudeMeter works best from your Applications folder. Would you like to move it there?"
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don\u{2019}t Ask Again")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            moveToApplications()
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: "declinedMoveToApplications")
        default:
            break
        }
    }

    private static func moveToApplications() {
        let source = Bundle.main.bundlePath
        let destination = "/Applications/" + (source as NSString).lastPathComponent
        let fm = FileManager.default

        do {
            if fm.fileExists(atPath: destination) {
                try fm.removeItem(atPath: destination)
            }
            try fm.copyItem(atPath: source, toPath: destination)
        } catch {
            NSLog("ClaudeMeter: Direct copy failed (%@), requesting privileges", error.localizedDescription)
            let src = source.replacingOccurrences(of: "'", with: "'\\''")
            let dst = destination.replacingOccurrences(of: "'", with: "'\\''")
            let script = "do shell script \"rm -rf '\(dst)'; cp -R '\(src)' '\(dst)'\" with administrator privileges"
            guard let appleScript = NSAppleScript(source: script) else {
                showError("Move Failed", "Could not prepare the authorization request.")
                return
            }
            var err: NSDictionary?
            appleScript.executeAndReturnError(&err)
            if err != nil {
                showError("Move Failed", "Could not copy ClaudeMeter to Applications.\nYou can drag it there manually.")
                return
            }
        }

        // Launch the new copy and quit
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: destination),
            configuration: .init()
        ) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Check for Updates

    static func checkForUpdates(silent: Bool = false) {
        let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard let data = data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    if !silent {
                        showError("Update Check Failed",
                                  "Could not reach GitHub. Check your internet connection.")
                    }
                    return
                }

                let remote = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

                guard isNewer(remote, than: currentVersion) else {
                    if !silent {
                        showInfo("You\u{2019}re Up to Date",
                                 "ClaudeMeter \(currentVersion) is the latest version.")
                    }
                    return
                }

                let assets = json["assets"] as? [[String: Any]] ?? []
                let zipURL = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                    .flatMap { $0["browser_download_url"] as? String }
                let notes = json["body"] as? String ?? ""

                promptUpdate(version: remote, notes: notes, zipURL: zipURL)
            }
        }.resume()
    }

    private static func promptUpdate(version: String, notes: String, zipURL: String?) {
        let alert = NSAlert()
        alert.messageText = "ClaudeMeter \(version) Available"
        let trimmed = notes.count > 500 ? String(notes.prefix(500)) + "\u{2026}" : notes
        alert.informativeText = "You\u{2019}re running \(currentVersion).\n\n\(trimmed)"

        if zipURL != nil, isAppBundle {
            alert.addButton(withTitle: "Update & Restart")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "Open Download Page")
            alert.addButton(withTitle: "Later")
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let zipURL = zipURL, isAppBundle {
            downloadAndInstall(zipURL)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(githubRepo)/releases/latest")!)
        }
    }

    // MARK: - Download & Install

    private static func downloadAndInstall(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }

        URLSession.shared.downloadTask(with: url) { tempFile, _, error in
            DispatchQueue.main.async {
                guard let tempFile = tempFile, error == nil else {
                    showError("Download Failed",
                              "Could not download the update. Try again later.")
                    return
                }
                install(from: tempFile)
            }
        }.resume()
    }

    private static func install(from zipFile: URL) {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("ClaudeMeter-update-\(UUID().uuidString)")

        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

            // Move the downloaded zip before the system cleans it up
            let zipDest = workDir.appendingPathComponent("update.zip")
            try fm.moveItem(at: zipFile, to: zipDest)

            // Unzip
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", zipDest.path, "-d", workDir.path]
            unzip.standardOutput = nil
            unzip.standardError = nil
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else {
                throw NSError(domain: "AppUpdater", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not extract the update archive."])
            }

            // Find the .app in the extracted contents
            let items = try fm.contentsOfDirectory(atPath: workDir.path)
            guard let appName = items.first(where: { $0.hasSuffix(".app") }) else {
                throw NSError(domain: "AppUpdater", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No app bundle found in the update archive."])
            }
            let newAppPath = workDir.appendingPathComponent(appName).path
            let currentAppPath = Bundle.main.bundlePath
            let pid = ProcessInfo.processInfo.processIdentifier

            // Updater script: waits for quit, replaces app, relaunches
            let scriptPath = fm.temporaryDirectory.appendingPathComponent("claudemeter-update.sh").path
            let script = """
            #!/bin/bash
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            rm -rf "$2"
            mv "$3" "$2"
            xattr -dr com.apple.quarantine "$2" 2>/dev/null
            open "$2"
            rm -rf "$4"
            rm -f "$0"
            """
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

            let updater = Process()
            updater.executableURL = URL(fileURLWithPath: "/bin/bash")
            updater.arguments = [scriptPath, "\(pid)", currentAppPath, newAppPath, workDir.path]
            try updater.run()

            NSApp.terminate(nil)
        } catch {
            showError("Update Failed", error.localizedDescription)
            try? fm.removeItem(at: workDir)
        }
    }

    // MARK: - Version Comparison

    private static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    // MARK: - Alerts

    private static func showError(_ title: String, _ message: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }

    private static func showInfo(_ title: String, _ message: String) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = message
        a.runModal()
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
        guard let password = keychainPassword() else {
            NSLog("ClaudeMeter: Failed to read encryption key from Keychain (service: %@)", keychainService)
            return nil
        }
        guard let aesKey = deriveKey(password: password) else {
            NSLog("ClaudeMeter: Failed to derive AES key from Keychain password")
            return nil
        }

        // 2. Copy the DB (Claude Desktop may have it locked)
        let tmpPath = NSTemporaryDirectory() + "claude_cookies_\(ProcessInfo.processInfo.processIdentifier).db"
        try? FileManager.default.removeItem(atPath: tmpPath)
        guard (try? FileManager.default.copyItem(atPath: dbPath, toPath: tmpPath)) != nil else {
            NSLog("ClaudeMeter: Cookie database not found at %@", dbPath)
            return nil
        }
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
    // 1003 iterations and "saltysalt" are Chromium's hardcoded values for macOS cookie encryption.
    // These cannot be changed — they must match what Chrome/Electron wrote.

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
