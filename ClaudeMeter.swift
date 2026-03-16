import Cocoa
import WebKit

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

    // Update checking
    var updateCheckTimer: Timer?
    var updateAvailableVersion: String?
    var checkForUpdatesMenuItem: NSMenuItem?
    var versionMenuItem: NSMenuItem?
    var updateBadgeDot: NSView?
    var badgeRefreshCount: Int = 0
    var badgeIntervalMenuItem: NSMenuItem?

    static let showBadgeKey = "showMenuBarBadge"
    var showMenuBarBadge: Bool = UserDefaults.standard.bool(forKey: AppDelegate.showBadgeKey) {
        didSet {
            UserDefaults.standard.set(showMenuBarBadge, forKey: Self.showBadgeKey)
            applyBadgeVisibility()
        }
    }

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
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.moveToAppsDelay) {
            AppUpdater.promptMoveToApplicationsIfNeeded()
        }

        // Silent update check after delay, then every 4 hours
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.updateCheckDelay) { [weak self] in
            self?.silentUpdateCheck()
        }
        startUpdateCheckTimer()
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
            let current = self.popover.contentSize.height
            // Only animate if height changed meaningfully — sub-pixel layout
            // rounding differences would otherwise cause the popover to flicker.
            guard abs(clamped - current) > 2 else { return }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.postLoadScrapeDelay) { [weak self] in
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

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[ClaudeMeter] Navigation failed: %@", error.localizedDescription)
        usageView?.setStatusFresh(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("[ClaudeMeter] Provisional navigation failed: %@", error.localizedDescription)
        usageView?.setStatusFresh(false)
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
        let updateItem = NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(checkForUpdates), keyEquivalent: "u")
        checkForUpdatesMenuItem = updateItem
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem.separator())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let verItem = NSMenuItem(title: "v\(version) (\(build))", action: nil, keyEquivalent: "")
        verItem.isEnabled = false
        versionMenuItem = verItem
        menu.addItem(verItem)
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
            // Only show skeleton on first open; subsequent opens display
            // the last known data immediately while refreshing in the background.
            if usageView?.hasContent != true {
                usageView?.showLoadingSkeleton()
                if let h = usageView?.skeletonHeight {
                    popover.contentSize = NSSize(width: 400, height: h)
                }
            } else {
                usageView?.setStatusLoading()
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
        webView.evaluateJavaScript(SharedJS.clickRefreshButton) { [weak self] result, _ in
            if (result as? String) == "clicked" {
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.silentRefreshWait) {
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

    // MARK: - Update Check Polling

    func startUpdateCheckTimer() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: Timing.updateCheckInterval, repeats: true) { [weak self] _ in
            self?.silentUpdateCheck()
        }
        updateCheckTimer?.tolerance = 300
    }

    func silentUpdateCheck() {
        AppUpdater.checkAvailableUpdate { [weak self] version in
            guard let self = self else { return }
            if let version = version {
                self.markUpdateAvailable(version)
            }
        }
    }

    func markUpdateAvailable(_ version: String) {
        guard updateAvailableVersion != version else { return }
        updateAvailableVersion = version

        // Update menu items
        checkForUpdatesMenuItem?.title = "Update Available \u{2013} v\(version)"
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        versionMenuItem?.title = "v\(current) (\(build)) \u{2192} v\(version)"

        // Add notification dot to menu bar icon
        showUpdateBadge(true)
    }

    func showUpdateBadge(_ show: Bool) {
        guard let button = statusItem.button else { return }
        updateBadgeDot?.removeFromSuperview()
        updateBadgeDot = nil
        guard show else { return }

        let dot = NSView()
        dot.wantsLayer = true
        // Subtle warm amber — noticeable but not alarming
        dot.layer?.backgroundColor = NSColor(red: 0xd4/255.0, green: 0xa8/255.0, blue: 0x43/255.0, alpha: 0.85).cgColor
        dot.layer?.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            dot.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
            dot.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
        ])
        updateBadgeDot = dot
    }

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
        webView.evaluateJavaScript(SharedJS.clickRefreshButton) { [weak self] result, error in
            if let error = error {
                NSLog("[ClaudeMeter] silentRefresh JS error: \(error.localizedDescription)")
            } else {
                NSLog("[ClaudeMeter] silentRefresh result: \(result ?? "nil")")
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.silentRefreshWait) {
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
        if badgeRefreshCount >= 20 {
            badgeRefreshCount = 0
            NSLog("[ClaudeMeter] badgeRefresh: periodic full reload to reclaim WebView memory")
            webView.load(URLRequest(url: Self.usageURL))
            return
        }

        webView.evaluateJavaScript(SharedJS.clickRefreshButton) { [weak self] result, error in
            if let error = error {
                NSLog("[ClaudeMeter] badgeRefresh JS error: \(error.localizedDescription)")
            } else {
                NSLog("[ClaudeMeter] badgeRefresh result: \(result ?? "nil")")
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.silentRefreshWait) {
                    self?.updateMenuBarBadge()
                    self?.cleanupWebViewDOM()
                }
            }
        }
    }

    /// Remove heavy DOM elements after badge scraping to reduce memory growth.
    func cleanupWebViewDOM() {
        let cleanupJS = "document.querySelectorAll('img, video, iframe, canvas, [data-testid=\"sidebar\"]').forEach(function(el){ el.remove(); });"
        webView.evaluateJavaScript(cleanupJS, completionHandler: nil)
    }

    func popoverDidClose(_ notification: Notification) {
        NSLog("[ClaudeMeter] popoverDidClose, stopping polling")
        stopPolling()
        if showMenuBarBadge {
            NSLog("[ClaudeMeter] badge enabled, updating badge and starting polling")
            updateMenuBarBadge()   // Immediate update with latest scraped data
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
        // Don't change badge while the popover is shown — resizing the status
        // item shifts the popover anchor and causes visible flicker.
        guard popover?.isShown != true else { return }
        webView.evaluateJavaScript(UsageScraper.scrapeSessionPercentageJS) { [weak self] result, _ in
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
        webView.evaluateJavaScript(UsageScraper.scrapeUsageJS) { [weak self] result, error in
            guard let self = self, let jsonStr = result as? String, !jsonStr.isEmpty else {
                if let error = error {
                    NSLog("[ClaudeMeter] scrapeAndUpdateUI error: %@", error.localizedDescription)
                } else {
                    NSLog("[ClaudeMeter] scrapeAndUpdateUI: no data scraped")
                }
                return
            }
            let sections = UsageScraper.parseUsageJSON(jsonStr)
            if UsageScraper.validateScrapeResult(sections) {
                NSLog("[ClaudeMeter] scraped \(sections.count) sections")
            } else {
                self.usageView?.setStatusFresh(false)
            }
            self.usageView?.update(sections: sections)
            self.usageView?.setStatusFresh(!sections.isEmpty)
        }
    }
}
