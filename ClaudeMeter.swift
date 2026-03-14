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
    var usageView: UsageContentView!
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
    static let badgeIntervalKey = "badgeRefreshInterval"
    static let badgeIntervalOptions: [(label: String, seconds: TimeInterval)] = [
        ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300), ("10 minutes", 600)
    ]
    var badgeRefreshInterval: TimeInterval = {
        let saved = UserDefaults.standard.double(forKey: AppDelegate.badgeIntervalKey)
        return saved > 0 ? saved : 120.0
    }()
    var badgeTimer: Timer?
    var badgeRefreshCount: Int = 0
    var badgeIntervalMenuItem: NSMenuItem?

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

    static let safariUA: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        // Safari major version tracks macOS major version + 3 (macOS 14→Safari 17, 15→18, etc.)
        let safariMajor = max(v.majorVersion + 3, 17)
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(v.majorVersion)_\(v.minorVersion)_\(v.patchVersion)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariMajor).0 Safari/605.1.15"
    }()
    static let usageURL = URL(string: "https://claude.ai/settings/usage")!
    static let loginURL = URL(string: "https://claude.ai/login")!

    /// JS to scrape all usage data as structured JSON from the page.
    /// Uses the same XPath approach as scrapeSessionPercentageJS (proven to work for the badge),
    /// extended to find ALL percentage meters and their surrounding context.
    /// Uses textContent (not innerText) for boundary detection since Claude's page
    /// uses CSS layout that causes innerText to return empty at intermediate levels.
    static let scrapeUsageJS = """
    (function(){
        try {
            var data = [];
            var snap = document.evaluate(
                "//text()[contains(., '% used')]",
                document.body, null,
                XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null
            );
            function leafTexts(node, max) {
                var r = [];
                if (r.length >= (max || 200)) return r;
                if (node.nodeType === 3) {
                    var t = node.textContent.trim();
                    if (t) r.push(t);
                } else if (node.nodeType === 1) {
                    for (var c = 0; c < node.childNodes.length && r.length < (max || 200); c++) {
                        r = r.concat(leafTexts(node.childNodes[c], max));
                    }
                }
                return r;
            }
            for (var i = 0; i < snap.snapshotLength; i++) {
                var node = snap.snapshotItem(i);
                var m = node.textContent.match(/(\\d+)%\\s*used/);
                if (!m) continue;
                var pct = parseInt(m[1], 10);
                var el = node.parentElement;
                var card = el;
                for (var j = 0; j < 10 && el; j++) {
                    var cnt = (el.textContent.match(/\\d+%\\s*used/g) || []).length;
                    if (cnt > 1) break;
                    card = el;
                    el = el.parentElement;
                }
                var texts = leafTexts(card, 50);
                var label = '';
                var detail = '';
                for (var k = 0; k < texts.length; k++) {
                    var t = texts[k];
                    if (/\\d+%\\s*used/.test(t)) continue;
                    if (/\\d+%/.test(t)) continue;
                    if (/reset/i.test(t) && !detail) { detail = t; continue; }
                    if (/last updated/i.test(t) || /learn more/i.test(t)) continue;
                    if (!label && t.length < 50 && t.length > 1) label = t;
                }
                var section = '';
                el = card.parentElement;
                for (var j = 0; j < 4 && el; j++) {
                    var sTexts = leafTexts(el, 100);
                    for (var s = 0; s < sTexts.length; s++) {
                        if (/limit/i.test(sTexts[s]) && sTexts[s].length < 40 && sTexts[s].length > 3) {
                            section = sTexts[s];
                            break;
                        }
                    }
                    if (section) break;
                    el = el.parentElement;
                }
                data.push({section: section, label: label, percentage: pct, detail: detail});
            }
            return JSON.stringify(data);
        } catch(e) { return '[]'; }
    })()
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

        setupMenu()
        setupPopover()
        applyBadgeVisibility()

        // Prompt to move to /Applications if not already there
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AppUpdater.promptMoveToApplicationsIfNeeded()
        }
    }

    // MARK: - Popover

    func setupPopover() {
        // WKWebView is kept off-screen for data scraping only
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = Self.safariUA

        // Import cookies and start loading
        hasAttemptedDesktopImport = true
        importFromClaudeDesktop { [weak self] success in
            guard let self = self else { return }
            self.webView.load(URLRequest(url: Self.usageURL))
        }

        // Native popover content — sized to skeleton, auto-resizes on content load
        usageView = UsageContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let skeletonH = usageView.skeletonHeight

        let vc = NSViewController()
        vc.view = usageView
        vc.view.frame = NSRect(x: 0, y: 0, width: 400, height: skeletonH)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: skeletonH)
        popover.behavior = .transient
        popover.contentViewController = vc
        popover.delegate = self
        popover.animates = true

        usageView.onContentSizeChanged = { [weak self] height in
            guard let self = self else { return }
            let clamped = min(max(height, 120), 500)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.allowsImplicitAnimation = true
                self.popover.contentSize = NSSize(width: 400, height: clamped)
            }
        }
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
            lastRefreshDate = Date()
            usageView?.setStatusFresh(true)
            // Scrape immediately for popover, then again after React renders for badge
            scrapeAndUpdateUI()
            updateMenuBarBadge()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self else { return }
                self.scrapeAndUpdateUI()
                self.updateMenuBarBadge()
                // Ensure badge polling is running after initial page load
                if self.showMenuBarBadge && self.popover?.isShown != true && self.badgeTimer == nil {
                    self.startBadgePolling()
                }
            }
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

        menu.addItem(NSMenuItem.separator())

        let badgeItem = NSMenuItem(title: "Show Usage in Menu Bar", action: #selector(toggleBadge(_:)), keyEquivalent: "b")
        badgeItem.target = self
        badgeItem.state = showMenuBarBadge ? .on : .off
        menu.addItem(badgeItem)

        let badgeIntervalItem = NSMenuItem(title: "Badge Refresh Interval", action: nil, keyEquivalent: "")
        let badgeIntervalSubmenu = NSMenu()
        for option in Self.badgeIntervalOptions {
            let item = NSMenuItem(title: option.label, action: #selector(setBadgeInterval(_:)), keyEquivalent: "")
            item.tag = Int(option.seconds)
            item.target = self
            if option.seconds == badgeRefreshInterval {
                item.state = .on
            }
            badgeIntervalSubmenu.addItem(item)
        }
        badgeIntervalItem.submenu = badgeIntervalSubmenu
        badgeIntervalItem.isEnabled = showMenuBarBadge
        badgeIntervalMenuItem = badgeIntervalItem
        menu.addItem(badgeIntervalItem)

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
        badgeIntervalMenuItem?.isEnabled = showMenuBarBadge
    }

    @objc func setBadgeInterval(_ sender: NSMenuItem) {
        let seconds = TimeInterval(sender.tag)
        badgeRefreshInterval = seconds
        UserDefaults.standard.set(seconds, forKey: Self.badgeIntervalKey)

        if let submenu = sender.menu {
            for item in submenu.items { item.state = .off }
        }
        sender.state = .on

        // Restart badge polling if active
        if badgeTimer != nil {
            startBadgePolling()
        }
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
            stopBadgePolling()
            usageView?.showLoadingSkeleton()
            if let h = usageView?.skeletonHeight {
                popover.contentSize = NSSize(width: 400, height: h)
            }
            softReload()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            startPolling()
        }
    }

    /// Soft reload: if already on the usage page, click the site's own refresh button.
    /// Falls back to a full page reload if needed.
    func softReload() {
        guard let url = webView.url?.absoluteString, url.contains("/settings/usage") else {
            gracefulReload()
            return
        }
        usageView?.setStatusLoading()
        let js = """
        (function() {
            var btns = document.querySelectorAll('button');
            for (var b of btns) {
                if (b.querySelector('svg') && b.closest('[class*="justify-between"]') &&
                    b.closest('[class*="text-xs"]')) {
                    b.click();
                    return 'clicked';
                }
            }
            return 'not_found';
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            if (result as? String) == "clicked" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.lastRefreshDate = Date()
                    self?.scrapeAndUpdateUI()
                    self?.updateMenuBarBadge()
                }
            } else {
                self?.gracefulReload()
            }
        }
    }

    /// Full page reload.
    func gracefulReload() {
        usageView?.setStatusLoading()
        webView.load(URLRequest(url: Self.usageURL))
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
        refreshTimer?.tolerance = statusFreshnessInterval * 0.1
    }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func startBadgePolling() {
        badgeTimer?.invalidate()
        NSLog("[ClaudeMeter] startBadgePolling: interval=\(badgeRefreshInterval)s")
        badgeTimer = Timer.scheduledTimer(withTimeInterval: badgeRefreshInterval, repeats: true) { [weak self] _ in
            NSLog("[ClaudeMeter] badge timer fired, calling badgeRefresh")
            self?.badgeRefresh()
        }
        badgeTimer?.tolerance = badgeRefreshInterval * 0.1
    }

    func stopBadgePolling() {
        badgeTimer?.invalidate()
        badgeTimer = nil
    }

    /// Silent refresh: clicks the site's refresh button and scrapes updated data.
    func silentRefresh() {
        guard popover?.isShown == true,
              let url = webView.url?.absoluteString, url.contains("/settings/usage") else { return }
        let js = """
        (function() {
            var btns = document.querySelectorAll('button');
            for (var b of btns) {
                if (b.querySelector('svg') && b.closest('[class*="justify-between"]') &&
                    b.closest('[class*="text-xs"]')) {
                    b.click();
                    return 'clicked';
                }
            }
            return 'not_found';
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            if let error = error {
                NSLog("[ClaudeMeter] silentRefresh JS error: \(error.localizedDescription)")
            } else {
                NSLog("[ClaudeMeter] silentRefresh result: \(result ?? "nil")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.lastRefreshDate = Date()
                    self?.scrapeAndUpdateUI()
                    self?.updateMenuBarBadge()
                }
            }
        }
    }

    /// Background badge refresh: clicks the site's refresh button and scrapes the percentage.
    /// Runs on the badge timer when the popover is closed but badge is enabled.
    func badgeRefresh() {
        guard showMenuBarBadge, popover?.isShown != true,
              let url = webView.url?.absoluteString, url.contains("/settings/usage") else { return }

        // Periodic full WebView reload to prevent unbounded memory growth
        badgeRefreshCount += 1
        if badgeRefreshCount >= 30 {
            badgeRefreshCount = 0
            NSLog("[ClaudeMeter] badgeRefresh: periodic full reload to reclaim WebView memory")
            webView.load(URLRequest(url: Self.usageURL))
            return
        }

        let js = """
        (function() {
            var btns = document.querySelectorAll('button');
            for (var b of btns) {
                if (b.querySelector('svg') && b.closest('[class*="justify-between"]') &&
                    b.closest('[class*="text-xs"]')) {
                    b.click();
                    return 'clicked';
                }
            }
            return 'not_found';
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            if let error = error {
                NSLog("[ClaudeMeter] badgeRefresh JS error: \(error.localizedDescription)")
            } else {
                NSLog("[ClaudeMeter] badgeRefresh result: \(result ?? "nil")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.updateMenuBarBadge()
                }
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        NSLog("[ClaudeMeter] popoverDidClose, stopping polling")
        stopPolling()
        if showMenuBarBadge {
            NSLog("[ClaudeMeter] badge enabled, starting badge polling")
            startBadgePolling()
        }
    }

    // MARK: - Menu Bar Badge

    func applyBadgeVisibility() {
        guard let button = statusItem.button else { return }
        badgeIntervalMenuItem?.isEnabled = showMenuBarBadge
        if showMenuBarBadge {
            button.imagePosition = .imageLeading
            // Restore cached value instantly, or show placeholder
            let cached = UserDefaults.standard.integer(forKey: "lastBadgePercentage")
            button.title = cached > 0 ? "\(cached)%" : "\u{2014}%"
            updateMenuBarBadge()
            // Start background badge polling if popover isn't open
            if popover?.isShown != true {
                startBadgePolling()
            }
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            stopBadgePolling()
        }
    }

    func updateMenuBarBadge() {
        guard showMenuBarBadge, webView != nil else { return }
        webView.evaluateJavaScript(Self.scrapeSessionPercentageJS) { [weak self] result, _ in
            guard let self = self else { return }
            if let percentage = result as? Int {
                self.statusItem.button?.title = "\(percentage)%"
                UserDefaults.standard.set(percentage, forKey: "lastBadgePercentage")
            } else if self.statusItem.button?.title.isEmpty == true {
                self.statusItem.button?.title = "\u{2014}%"
            }
        }
    }

    private func isLoginURL(_ url: String) -> Bool {
        url.contains("/login") || url.contains("/signin") || url.contains("accounts.google.com")
    }

    // MARK: - Scrape & Native UI Update

    func scrapeAndUpdateUI() {
        webView.evaluateJavaScript(Self.scrapeUsageJS) { [weak self] result, error in
            guard let self = self, let jsonStr = result as? String, !jsonStr.isEmpty else {
                NSLog("[ClaudeMeter] scrapeAndUpdateUI: no data scraped")
                return
            }
            let sections = Self.parseUsageJSON(jsonStr)
            NSLog("[ClaudeMeter] scraped \(sections.count) sections")
            self.usageView?.update(sections: sections)
            self.usageView?.setStatusFresh(true)
        }
    }

    static func parseUsageJSON(_ jsonString: String) -> [UsageSection] {
        guard let data = jsonString.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var orderedSections: [String] = []
        var sectionMeters: [String: [UsageMeter]] = [:]

        for item in items {
            let section = item["section"] as? String ?? ""
            let label = item["label"] as? String ?? ""
            let percentage = item["percentage"] as? Int ?? 0
            let detail = item["detail"] as? String ?? ""

            let meter = UsageMeter(label: label, percentage: percentage, detail: detail)

            if sectionMeters[section] == nil {
                orderedSections.append(section)
                sectionMeters[section] = []
            }
            sectionMeters[section]!.append(meter)
        }

        return orderedSections.compactMap { key in
            guard let meters = sectionMeters[key] else { return nil }
            return UsageSection(title: key, meters: meters)
        }
    }
}

// MARK: - Usage Data Model

struct UsageMeter {
    let label: String
    let percentage: Int
    let detail: String
}

struct UsageSection {
    let title: String
    let meters: [UsageMeter]
}

// MARK: - Native Usage View

class UsageContentView: NSView {
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let statusDot = NSView()
    var onContentSizeChanged: ((CGFloat) -> Void)?
    private var skeletonShownAt: Date?
    private static let minSkeletonDuration: TimeInterval = 0.6

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0x1a/255.0, green: 0x1a/255.0, blue: 0x1a/255.0, alpha: 1).cgColor

        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        // Stack view inside scroll view
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        scrollView.documentView = stackView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // Status dot
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor.gray.cgColor
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusDot)
        NSLayoutConstraint.activate([
            statusDot.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            statusDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        // Initial loading skeleton (callback not wired yet — size set by AppDelegate)
        showLoadingSkeleton()
    }

    /// The natural height of the skeleton, used to set the initial popover size.
    var skeletonHeight: CGFloat {
        stackView.layoutSubtreeIfNeeded()
        return stackView.fittingSize.height
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(sections: [UsageSection]) {
        // If skeleton is still showing, ensure minimum display time
        if let shown = skeletonShownAt {
            let elapsed = Date().timeIntervalSince(shown)
            let remaining = Self.minSkeletonDuration - elapsed
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    self?.doUpdate(sections: sections)
                }
                return
            }
        }
        doUpdate(sections: sections)
    }

    private func doUpdate(sections: [UsageSection]) {
        let wasShowingSkeleton = skeletonShownAt != nil
        skeletonShownAt = nil

        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if sections.isEmpty {
            let empty = makeLabel("No usage data available", size: 13, color: NSColor(white: 0.5, alpha: 1))
            stackView.addArrangedSubview(empty)
            return
        }

        for (i, section) in sections.enumerated() {
            if i > 0 {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: 2).isActive = true
                stackView.addArrangedSubview(spacer)

                let divider = NSView()
                divider.wantsLayer = true
                divider.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stackView.addArrangedSubview(divider)
                divider.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: 16).isActive = true
                divider.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -16).isActive = true
                stackView.setCustomSpacing(6, after: divider)
            }

            // Section title
            if !section.title.isEmpty {
                let title = makeLabel(section.title.uppercased(), size: 10, weight: .semibold,
                                      color: NSColor(white: 0.5, alpha: 1))
                title.allowsDefaultTighteningForTruncation = true
                stackView.addArrangedSubview(title)
                stackView.setCustomSpacing(6, after: title)
            }

            for meter in section.meters {
                addMeter(meter)
            }
        }

        // Crossfade from skeleton to real content
        if wasShowingSkeleton {
            scrollView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.animator().alphaValue = 1
            }
        }

        stackView.layoutSubtreeIfNeeded()
        let fittingHeight = stackView.fittingSize.height
        onContentSizeChanged?(fittingHeight)
    }

    // MARK: - Loading Skeleton

    func showLoadingSkeleton() {
        skeletonShownAt = Date()
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let barWidth: CGFloat = 368

        // Simulate 2 sections with 2 meters each
        for section in 0..<2 {
            if section > 0 {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: 2).isActive = true
                stackView.addArrangedSubview(spacer)

                let divider = NSView()
                divider.wantsLayer = true
                divider.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stackView.addArrangedSubview(divider)
                divider.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: 16).isActive = true
                divider.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -16).isActive = true
                stackView.setCustomSpacing(6, after: divider)
            }

            // Section title skeleton
            let titleBar = makeShimmerBar(width: 120, height: 10)
            stackView.addArrangedSubview(titleBar)
            stackView.setCustomSpacing(6, after: titleBar)

            for meter in 0..<2 {
                // Label row skeleton
                let row = NSStackView()
                row.orientation = .horizontal
                row.distribution = .fill
                row.translatesAutoresizingMaskIntoConstraints = false
                row.widthAnchor.constraint(equalToConstant: barWidth).isActive = true

                let nameW: CGFloat = meter == 0 ? 110 : 80
                let nameBar = makeShimmerBar(width: nameW, height: 12, flexible: true)
                let pctBar = makeShimmerBar(width: 32, height: 12)
                pctBar.setContentHuggingPriority(.required, for: .horizontal)
                row.addArrangedSubview(nameBar)
                row.addArrangedSubview(pctBar)

                stackView.addArrangedSubview(row)
                stackView.setCustomSpacing(4, after: row)

                // Progress bar skeleton
                let track = makeShimmerBar(width: barWidth, height: 6, cornerRadius: 3)
                stackView.addArrangedSubview(track)
                stackView.setCustomSpacing(2, after: track)

                // Detail skeleton
                let detailBar = makeShimmerBar(width: meter == 0 ? 130 : 90, height: 10)
                stackView.addArrangedSubview(detailBar)
                stackView.setCustomSpacing(6, after: detailBar)
            }
        }

        stackView.layoutSubtreeIfNeeded()
        onContentSizeChanged?(stackView.fittingSize.height)
    }

    private func makeShimmerBar(width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 4, flexible: Bool = false) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        if flexible {
            view.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        view.heightAnchor.constraint(equalToConstant: height).isActive = true

        let base = NSColor(white: 0.18, alpha: 1)
        let highlight = NSColor(white: 0.28, alpha: 1)

        let gradient = CAGradientLayer()
        gradient.colors = [base.cgColor, highlight.cgColor, base.cgColor]
        gradient.locations = [0, 0.5, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.frame = CGRect(x: 0, y: 0, width: width * 3, height: height)
        view.layer?.addSublayer(gradient)

        let anim = CABasicAnimation(keyPath: "transform.translation.x")
        anim.fromValue = -width * 2
        anim.toValue = 0
        anim.duration = 1.2
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradient.add(anim, forKey: "shimmer")

        return view
    }

    private func addMeter(_ meter: UsageMeter) {
        let barWidth: CGFloat = 368

        // Label row
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: barWidth).isActive = true

        let name = makeLabel(meter.label.isEmpty ? "Usage" : meter.label, size: 13, weight: .medium, color: .white)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let pct = makeLabel("\(meter.percentage)%", size: 13, weight: .medium,
                            color: colorForPercentage(meter.percentage))
        pct.alignment = .right
        pct.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(name)
        row.addArrangedSubview(pct)
        stackView.addArrangedSubview(row)
        stackView.setCustomSpacing(4, after: row)

        // Progress bar
        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        track.layer?.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false
        track.heightAnchor.constraint(equalToConstant: 6).isActive = true
        track.widthAnchor.constraint(equalToConstant: barWidth).isActive = true

        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = colorForPercentage(meter.percentage).cgColor
        fill.layer?.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor,
                                        multiplier: max(CGFloat(min(meter.percentage, 100)) / 100.0, 0.01)),
        ])

        stackView.addArrangedSubview(track)

        // Detail
        if !meter.detail.isEmpty {
            stackView.setCustomSpacing(2, after: track)
            let detail = makeLabel(meter.detail, size: 11, color: NSColor(white: 0.45, alpha: 1))
            stackView.addArrangedSubview(detail)
            stackView.setCustomSpacing(6, after: detail)
        } else {
            stackView.setCustomSpacing(6, after: track)
        }
    }

    // MARK: - Status Dot

    func setStatusFresh(_ fresh: Bool) {
        statusDot.layer?.backgroundColor = fresh
            ? NSColor(red: 0x34/255.0, green: 0xd3/255.0, blue: 0x99/255.0, alpha: 1).cgColor
            : NSColor.gray.cgColor
    }

    func setStatusLoading() {
        statusDot.layer?.backgroundColor = NSColor(red: 0xd4/255.0, green: 0xa8/255.0, blue: 0x43/255.0, alpha: 1).cgColor
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                           color: NSColor = .white) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func colorForPercentage(_ pct: Int) -> NSColor {
        switch pct {
        case 0..<50: return NSColor(red: 0x34/255.0, green: 0xd3/255.0, blue: 0x99/255.0, alpha: 1)
        case 50..<80: return NSColor(red: 0xfb/255.0, green: 0xbf/255.0, blue: 0x24/255.0, alpha: 1)
        case 80..<95: return NSColor(red: 0xf9/255.0, green: 0x73/255.0, blue: 0x16/255.0, alpha: 1)
        default: return NSColor(red: 0xef/255.0, green: 0x44/255.0, blue: 0x44/255.0, alpha: 1)
        }
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

            // Verify code signature before replacing
            let codesign = Process()
            codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            codesign.arguments = ["--verify", "--deep", "--strict", newAppPath]
            let signPipe = Pipe()
            codesign.standardOutput = signPipe
            codesign.standardError = signPipe
            try codesign.run()
            codesign.waitUntilExit()
            if codesign.terminationStatus != 0 {
                let signOutput = String(data: signPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("ClaudeMeter: Code signature verification failed: %@", signOutput)
                showError("Update Failed",
                          "The downloaded app failed code signature verification and cannot be installed.")
                try? fm.removeItem(at: workDir)
                return
            }

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
            guard let hostPtr = sqlite3_column_text(stmt, 0),
                  let namePtr = sqlite3_column_text(stmt, 1),
                  let pathPtr = sqlite3_column_text(stmt, 2) else { continue }
            let host     = String(cString: hostPtr)
            let name     = String(cString: namePtr)
            let path     = String(cString: pathPtr)
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
