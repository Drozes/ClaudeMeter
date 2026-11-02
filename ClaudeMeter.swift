import Cocoa
import WebKit
import Security
import SQLite3
import CommonCrypto
import UserNotifications

@main
struct ClaudeMeterApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    // Per-account metering engines (WKWebView, timers, fetch state, history).
    // The first is always the primary (default-store) account that the
    // Claude Desktop import feeds; secondary accounts follow (macOS 14+).
    var accounts: [AccountController] = []
    // Accounts being added: kept alive until their sign-in completes or is
    // cancelled, but not metered or saved yet.
    var pendingAccounts: [AccountController] = []
    var signInMenuItem: NSMenuItem?
    var accountsMenuItems: [NSMenuItem] = []
    // Two or more accounts: the stacked popover view, each secondary
    // account's own usage view, and each badge side's last text.
    var multiAccountView: MultiAccountUsageView?
    var accountViews: [String: UsageContentView] = [:]
    var badgeSideText: [String: String] = [:]
    var badgeWasMulti = false
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

    // Menu bar badge
    static let badgeIntervalKey = "badgeRefreshInterval"
    static let badgeIntervalOptions: [(label: String, seconds: TimeInterval)] = [
        ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300), ("10 minutes", 600)
    ]
    var badgeRefreshInterval: TimeInterval = {
        let saved = UserDefaults.standard.double(forKey: AppDelegate.badgeIntervalKey)
        return saved > 0 ? saved : 120.0
    }()
    // v2.7: refresh the menu-bar tooltip between scrapes.
    var tooltipRefreshTimer: Timer?

    // Update checking
    var updateCheckTimer: Timer?
    var updateAvailableVersion: String?
    var checkForUpdatesMenuItem: NSMenuItem?
    var versionMenuItem: NSMenuItem?
    var updateBadgeDot: NSView?

    var badgeIntervalMenuItem: NSMenuItem?
    var notifier: ThresholdNotifier!
    var notificationsEnabledMenuItem: NSMenuItem?
    var notificationThresholdMenuItems: [NSMenuItem] = []

    static let showBadgeKey = "showMenuBarBadge"
    var showMenuBarBadge: Bool = UserDefaults.standard.bool(forKey: AppDelegate.showBadgeKey) {
        didSet {
            UserDefaults.standard.set(showMenuBarBadge, forKey: Self.showBadgeKey)
            applyBadgeVisibility()
        }
    }

    // Default-on prefs (v2.7). Bool-with-explicit-default pattern so users
    // who upgrade get the new visuals automatically; opting out persists.
    static let showBurnRateKey = "showBurnRate"
    static let showSparklineKey = "showSparkline"
    var showBurnRate: Bool = AppDelegate.boolPref(key: AppDelegate.showBurnRateKey, default: true) {
        didSet {
            UserDefaults.standard.set(showBurnRate, forKey: Self.showBurnRateKey)
            usageView?.showBurnRate = showBurnRate
            accountViews.values.forEach { $0.showBurnRate = showBurnRate }
        }
    }
    var showSparkline: Bool = AppDelegate.boolPref(key: AppDelegate.showSparklineKey, default: true) {
        didSet {
            UserDefaults.standard.set(showSparkline, forKey: Self.showSparklineKey)
            usageView?.showSparkline = showSparkline
            accountViews.values.forEach { $0.showSparkline = showSparkline }
        }
    }
    private static func boolPref(key: String, default defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }

    static let safariUA: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        // Safari major version tracks macOS major version + 3 (macOS 14→Safari 17, 15→18, etc.)
        let safariMajor = max(v.majorVersion + 3, 17)
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(v.majorVersion)_\(v.minorVersion)_\(v.patchVersion)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariMajor).0 Safari/605.1.15"
    }()
    static let usageURL = URL(string: "https://claude.ai/settings/usage")!
    static let loginURL = URL(string: "https://claude.ai/login")!

    // Anthropic peak-hour window. Single source of truth: update this struct if
    // the window shifts. Local display always uses Calendar.current; the peak
    // check uses the configured timeZone (DST handled automatically).
    struct PeakWindow {
        let startHour: Int
        let endHour: Int
        let timeZone: String
        let weekdaysOnly: Bool
    }
    static let peakWindow = PeakWindow(startHour: 5, endHour: 11, timeZone: "America/Los_Angeles", weekdaysOnly: true)

    static let apiOrgsURL = URL(string: "https://claude.ai/api/organizations")!
    static let apiUsagePath = "/api/organizations/%@/usage"
    static let forceDOMOnlyKey = "forceDOMOnly"
    // v2.7.1 global keys, now read only by AccountStore.migrateIfNeeded; the
    // values live on AccountRecord (org UUID, plan tier).
    static let cachedOrgUUIDKey = "cachedOrgUUID"
    static let cachedPlanTierKey = "cachedPlanTier"
    // Key families: per-account keys are "<family>.<accountId>" (AccountKeys).
    static let lastFetchPathKey = "lastFetchPath"
    static let lastBadgePercentageKey = "lastBadgePercentage"

    static func planTierDisplayName(slug: String?) -> String? {
        guard let s = slug?.lowercased(), !s.isEmpty else { return nil }
        switch s {
        case "default_claude_free":         return "Free"
        case "default_claude_pro":          return "Pro"
        case "default_claude_max_5x":       return "Max 5x"
        case "default_claude_max_20x":      return "Max 20x"
        case "default_claude_team":         return "Team"
        case "default_claude_enterprise":   return "Enterprise"
        default:
            // Titlecase the stem for unknown future tiers (e.g. max_50x).
            let stripped = s.replacingOccurrences(of: "default_claude_", with: "")
            guard !stripped.isEmpty else { return nil }
            return stripped.prefix(1).uppercased() + stripped.dropFirst()
        }
    }

    /// Direct XPath scrape for the "Current session" percentage. Independent
    /// fallback used by the badge when the structured scrape's label-detection
    /// fails to surface a "current session" meter (page DOM drift, label picked
    /// from an unrelated short text node, etc).
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

    /// JS to scrape all usage data as structured JSON from the page.
    /// Uses XPath to find ALL percentage meters and their surrounding context.
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
                var preferredLabel = '';
                var detail = '';
                // Preferred label patterns — anchor the badge on stable text
                // ("Current session", "Weekly usage", "Weekly Opus 4 usage", etc.)
                // so the meter the badge needs is always findable by label,
                // independent of DOM ordering of other short text in the card.
                var preferRe = /^(current session|weekly|opus|sonnet|haiku)/i;
                for (var k = 0; k < texts.length; k++) {
                    var t = texts[k];
                    if (/\\d+%\\s*used/.test(t)) continue;
                    if (/\\d+%/.test(t)) continue;
                    if (/reset/i.test(t) && !detail) { detail = t; continue; }
                    if (/last updated/i.test(t) || /learn more/i.test(t)) continue;
                    if (!preferredLabel && preferRe.test(t.trim())) preferredLabel = t.trim();
                    if (!label && t.length < 50 && t.length > 1) label = t;
                }
                if (preferredLabel) label = preferredLabel;
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

        // Copy v2.7.1's global per-account state into the primary account's
        // namespace once, before anything reads it.
        AccountStore.migrateIfNeeded()

        setupMenu()
        notifier = ThresholdNotifier()
        UNUserNotificationCenter.current().delegate = notifier
        setupPopover()
        applyBadgeVisibility()

        // Prompt to move to /Applications if not already there
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AppUpdater.promptMoveToApplicationsIfNeeded()
        }

        // Proactively populate plan tier so the chip works even when the
        // usage JSON path is circuit-broken. Wait long enough for cookies to
        // be imported and the WKWebView to attach them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.accounts.forEach { account in account.staggered { account.refreshPlanTierIfNeeded() } }
        }

        // Remove WebKit stores no account references (macOS 14+).
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.sweepOrphanedDataStores()
        }

        // Silent update check after 30s, then every 4 hours
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.silentUpdateCheck()
        }
        startUpdateCheckTimer()

        // v2.7 — refresh the menu-bar tooltip every minute so the "at HH:MM"
        // peak time stays current between scrapes.
        tooltipRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateMenuBarTooltip()
        }
        tooltipRefreshTimer?.tolerance = 10

        #if CLAUDEMETER_TESTHOOKS
        runQATestHooks()   // qa/multiaccount/testhooks.swift; never in release builds
        #endif
    }

    // MARK: - Popover

    func setupPopover() {
        // One AccountController per metered account. Each owns an off-screen
        // WKWebView (data scraping only). start() loads the usage page: the
        // primary account first imports Claude Desktop cookies; secondary
        // accounts load from their own isolated store, staggered.
        accounts = makeAccountControllers()
        normalizeBadgeSlots()
        let account = accounts[0]
        accounts.forEach { $0.start() }

        // Native popover content, sized to skeleton, auto-resizes on content load.
        usageView = UsageContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        account.usageView = usageView
        usageView.planTierDisplayName = Self.planTierDisplayName(slug: account.cachedPlanTier)
        usageView.showBurnRate = showBurnRate
        usageView.showSparkline = showSparkline
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
            self?.applyPopoverContentHeight(height)
        }

        badgeWasMulti = accounts.count >= 2
        rebuildAccountsMenu()
        rebuildPopoverContent()
    }

    // MARK: - Claude Desktop Cookie Import

    /// Claude Desktop's cookies always go to the primary account.
    @objc func importFromDesktop() {
        guard let account = accounts.first else { return }
        account.importFromClaudeDesktop { success in
            if success {
                account.webView.load(URLRequest(url: Self.usageURL))
            } else {
                let alert = NSAlert()
                alert.messageText = "Could not import session"
                alert.informativeText = "Make sure Claude Desktop is installed and you're signed in.\n\nAlternatively, use \"Sign In\u{2026}\" to log in with email."
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    // MARK: - Menu

    func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Reload", action: #selector(reload), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Import from Claude Desktop", action: #selector(importFromDesktop), keyEquivalent: "i"))
        let signIn = NSMenuItem(title: "Sign In\u{2026}", action: #selector(openLogin), keyEquivalent: "l")
        signInMenuItem = signIn
        menu.addItem(signIn)
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
        let burnRateItem = NSMenuItem(title: "Show Burn Rate Chip",
                                       action: #selector(toggleBurnRate(_:)),
                                       keyEquivalent: "")
        burnRateItem.target = self
        burnRateItem.state = showBurnRate ? .on : .off
        menu.addItem(burnRateItem)
        let sparklineItem = NSMenuItem(title: "Show 24h Sparkline",
                                        action: #selector(toggleSparkline(_:)),
                                        keyEquivalent: "")
        sparklineItem.target = self
        sparklineItem.state = showSparkline ? .on : .off
        menu.addItem(sparklineItem)

        let notificationsItem = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        let notificationsSubmenu = NSMenu()
        notificationThresholdMenuItems.removeAll()

        let enabledItem = NSMenuItem(title: "Enable Notifications", action: #selector(toggleNotificationsEnabled(_:)), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = UserDefaults.standard.bool(forKey: ThresholdNotifier.enabledKey) ? .on : .off
        notificationsEnabledMenuItem = enabledItem
        notificationsSubmenu.addItem(enabledItem)

        notificationsSubmenu.addItem(NSMenuItem.separator())

        for threshold in [50, 75, 90] {
            let item = NSMenuItem(title: "Session \(threshold)%", action: #selector(toggleThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "session.\(threshold)"
            let muted = UserDefaults.standard.bool(forKey: "notif.mute.session.\(threshold)")
            item.state = muted ? .off : .on
            notificationsSubmenu.addItem(item)
            notificationThresholdMenuItems.append(item)
        }

        notificationsSubmenu.addItem(NSMenuItem.separator())

        for threshold in [50, 75, 90] {
            let item = NSMenuItem(title: "Weekly \(threshold)%", action: #selector(toggleThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "weekly.\(threshold)"
            let muted = UserDefaults.standard.bool(forKey: "notif.mute.weekly.\(threshold)")
            item.state = muted ? .off : .on
            notificationsSubmenu.addItem(item)
            notificationThresholdMenuItems.append(item)
        }

        notificationsSubmenu.addItem(NSMenuItem.separator())
        let testItem = NSMenuItem(title: "Send Test Notification",
                                   action: #selector(sendTestNotification),
                                   keyEquivalent: "")
        testItem.target = self
        notificationsSubmenu.addItem(testItem)

        notificationsItem.submenu = notificationsSubmenu
        menu.addItem(notificationsItem)

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

    @objc func toggleNotificationsEnabled(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: ThresholdNotifier.enabledKey)
        UserDefaults.standard.set(!current, forKey: ThresholdNotifier.enabledKey)
        sender.state = !current ? .on : .off
    }

    @objc func toggleThreshold(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let muteKey = "notif.mute.\(key)"
        let currentlyMuted = UserDefaults.standard.bool(forKey: muteKey)
        UserDefaults.standard.set(!currentlyMuted, forKey: muteKey)
        sender.state = !currentlyMuted ? .off : .on
    }

    @objc func sendTestNotification() {
        notifier.sendTestNotification()
    }

    @objc func toggleBurnRate(_ sender: NSMenuItem) {
        showBurnRate.toggle()
        sender.state = showBurnRate ? .on : .off
    }

    @objc func toggleSparkline(_ sender: NSMenuItem) {
        showSparkline.toggle()
        sender.state = showSparkline ? .on : .off
    }

    @objc func setBadgeInterval(_ sender: NSMenuItem) {
        let seconds = TimeInterval(sender.tag)
        badgeRefreshInterval = seconds
        UserDefaults.standard.set(seconds, forKey: Self.badgeIntervalKey)

        if let submenu = sender.menu {
            for item in submenu.items { item.state = .off }
        }
        sender.state = .on

        // Restart timers that are active while the popover is closed
        if popover?.isShown != true {
            for account in accounts where account.refreshTimer != nil {
                account.startRefreshTimer()
            }
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

        // Restart timers that are active while the popover is open
        if popover?.isShown == true {
            for account in accounts where account.refreshTimer != nil {
                account.startRefreshTimer()
            }
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
            accounts.forEach { $0.stopRefreshTimer() }
            if accounts.count >= 2 {
                // Several accounts: skeleton per account without data yet,
                // then size the popover to all sections.
                rebuildPopoverContent()
                for account in accounts where !account.isSignedOut {
                    let view = usageView(for: account)
                    if view.hasContent { view.setStatusLoading() } else { view.showLoadingSkeleton() }
                }
                if let multi = multiAccountView {
                    let h = multi.contentHeight
                    popover.contentSize = NSSize(width: 400, height: min(max(h, 120), max(1200, (NSScreen.main?.visibleFrame.height ?? 1200) - 40)))
                }
            } else if usageView?.hasContent != true {
                // Only show skeleton on first open; subsequent opens display
                // the last known data immediately while refreshing in the background.
                usageView?.showLoadingSkeleton()
                if let h = usageView?.skeletonHeight {
                    popover.contentSize = NSSize(width: 400, height: h)
                }
            } else {
                usageView?.setStatusLoading()
            }
            accounts.forEach { account in account.staggered { account.softReload() } }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            if let multi = multiAccountView, accounts.count >= 2 {
                multi.scrollToTop()
            } else {
                usageView?.scrollToTop()
            }
            accounts.forEach { $0.startRefreshTimer() }
            activeUsageViews.forEach { $0.startCountdownTicker() }
        }
    }

    @objc func reload() { accounts.forEach { $0.gracefulReload() } }
    @objc func openLogin() { accounts.first?.showLoginWindow() }
    @objc func checkForUpdates() { AppUpdater.checkForUpdates() }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: - Update Check Polling

    func startUpdateCheckTimer() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
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

    func popoverDidClose(_ notification: Notification) {
        NSLog("[ClaudeMeter] popoverDidClose")
        accounts.forEach { $0.stopRefreshTimer() }
        activeUsageViews.forEach { $0.stopCountdownTicker() }
        accounts.forEach { $0.refreshCycleCount = 0 }
        syncBadgeMode()
        updateBadgeFromModel()
        if showMenuBarBadge {
            NSLog("[ClaudeMeter] badge enabled, starting background refresh")
            accounts.forEach { $0.startRefreshTimer() }
        }
    }

    // MARK: - Menu Bar Badge

    /// Centralized setter for the status-item title. Logs every change with a
    /// `reason` so the QA pipeline (and on-call operators) have a deterministic
    /// signal for whether the badge is updating, independent of OCR/screenshots.
    /// Skips the assignment if the value is unchanged to avoid layout churn.
    func setBadgeTitle(_ title: String, reason: String) {
        guard let button = statusItem.button else { return }
        let old = button.title
        if old == title { return }
        button.title = title
        // NSLog treats its first argument as a printf format string. The badge
        // value contains '%' (e.g. "47%") which NSLog would otherwise consume
        // as a format specifier, mangling the output. Always pass user-data
        // strings through "%@" instead of inlining them in the format string.
        NSLog("%@", "[ClaudeMeter] badge title: '\(old)' -> '\(title)' (\(reason))")
    }

    func applyBadgeVisibility() {
        guard statusItem.button != nil else { return }
        badgeIntervalMenuItem?.isEnabled = showMenuBarBadge
        if showMenuBarBadge {
            statusItem.button?.imagePosition = .imageLeading
            // Restore cached value instantly, or show placeholder
            restoreCachedBadge()
            updateBadgeFromModel()
            // Start background refresh if popover isn't open
            if popover?.isShown != true {
                accounts.forEach { $0.startRefreshTimer() }
            }
        } else {
            setBadgeTitle("", reason: "badge disabled")
            statusItem.button?.imagePosition = .imageOnly
            accounts.forEach { $0.stopRefreshTimer() }
        }
    }

    /// Update the menu bar badge from the shared data store, falling back to a
    /// direct XPath scrape if the model lacks a "current session" meter.
    /// The fallback preserves v1.7's robustness: badge updates as long as the
    /// page contains "Current session" text near a "% used" sibling.
    func updateBadgeFromModel() {
        guard showMenuBarBadge else { return }
        // Don't change badge while the popover is shown — resizing the status
        // item shifts the popover anchor and causes visible flicker.
        guard popover?.isShown != true else { return }
        // Two or more accounts: the two-slot badge ("P 47% | W 12%").
        if accounts.count >= 2 {
            updateMultiAccountBadge()
            return
        }
        // One account: the badge mirrors it exactly as in v2.7.1 ("47%").
        guard let account = accounts.first else { return }

        let badgeKey = account.lastBadgePercentageKey

        if let pct = account.sessionPercentage(from: account.latestSections) {
            setBadgeTitle("\(pct)%", reason: "model meter labeled current session")
            UserDefaults.standard.set(pct, forKey: badgeKey)
            return
        }

        // Fallback: direct XPath scrape (independent of structured scrape's labels).
        NSLog("[ClaudeMeter] updateBadgeFromModel: no 'current session' meter in model, falling back to XPath")
        account.webView.evaluateJavaScript(Self.scrapeSessionPercentageJS) { [weak self] result, _ in
            guard let self = self else { return }
            // Re-check guards on the JS callback — popover state may have changed.
            guard self.showMenuBarBadge, self.popover?.isShown != true else { return }
            if let pct = result as? Int {
                self.setBadgeTitle("\(pct)%", reason: "XPath fallback scrape")
                UserDefaults.standard.set(pct, forKey: badgeKey)
            } else if self.statusItem.button?.title.isEmpty == true {
                self.setBadgeTitle("\u{2014}%", reason: "XPath fallback returned nil")
            }
        }
    }

    /// v2.7 — Menu-bar tooltip with today's peak / 24h avg / streak,
    /// computed from the account's `history`. Idempotent and cheap (linear scan over
    /// at most ~720 samples). Called after every successful scrape and
    /// from a 1-min refresh tick so the "at HH:MM" timestamp doesn't go
    /// stale between fetches.
    func updateMenuBarTooltip() {
        guard let button = statusItem.button else { return }
        if accounts.count >= 2 {
            button.toolTip = multiAccountTooltip()
            return
        }
        let samples = accounts.first?.history.samples ?? []
        guard !samples.isEmpty else {
            button.toolTip = "ClaudeMeter — no usage data yet"
            return
        }

        // Peak session pct in the last 24h (history is already 24h-bounded).
        let peak = samples.max { $0.s < $1.s }!
        let peakDate = Date(timeIntervalSince1970: peak.t)
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "a"; f.pmSymbol = "p"
        let peakTime = f.string(from: peakDate).lowercased()

        // 24h average session pct (mean of all retained samples).
        let avg = Int((Double(samples.reduce(0) { $0 + $1.s }) / Double(samples.count)).rounded())

        var lines = ["Peak: \(peak.s)% at \(peakTime) · 24h avg: \(avg)%"]

        // Streak: how many consecutive recent samples were < 90%? Useful as
        // a "you've been pacing well" signal once history grows.
        var streak = 0
        for s in samples.reversed() {
            if s.s < 90 { streak += 1 } else { break }
        }
        if streak >= 5 {
            lines.append("Streak under 90%: \(streak) samples")
        }

        if let forecast = accounts.first?.lastSessionForecast, case .ok = forecast.state, forecast.ratePerHour >= 0.05 {
            let rate = forecast.ratePerHour
            let formatted: String
            if rate >= 10 { formatted = String(format: "%.0f%%/h", rate) }
            else { formatted = String(format: "%.1f%%/h", rate) }
            lines.append("Burn rate: +\(formatted)")
        }

        button.toolTip = lines.joined(separator: "\n")
    }

    // MARK: - Peak Window

    /// True when "now" lies inside the configured peak-hour window (Mon-Fri
    /// 5-11 AM Pacific by default). DST handled automatically by TimeZone.
    static func isInPeakWindow(now: Date = Date()) -> Bool {
        guard let tz = TimeZone(identifier: peakWindow.timeZone) else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let hour = cal.component(.hour, from: now)
        let weekday = cal.component(.weekday, from: now)
        if peakWindow.weekdaysOnly && !(2...6).contains(weekday) { return false }
        return hour >= peakWindow.startHour && hour < peakWindow.endHour
    }

    /// Time remaining until the peak window closes today. Returns nil when not
    /// currently in the peak window.
    static func peakWindowRemaining(now: Date = Date()) -> TimeInterval? {
        guard isInPeakWindow(now: now), let tz = TimeZone(identifier: peakWindow.timeZone) else {
            return nil
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = peakWindow.endHour
        comps.minute = 0
        comps.second = 0
        guard let endDate = cal.date(from: comps) else { return nil }
        return max(0, endDate.timeIntervalSince(now))
    }
}

// MARK: - Accounts: menu and management

extension AppDelegate {
    /// Adding accounts needs isolated WebKit stores (WKWebsiteDataStore
    /// forIdentifier:), which exist on macOS 14 and later only.
    var canAddAccounts: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    func account(withID id: String?) -> AccountController? {
        guard let id = id else { return nil }
        return accounts.first { $0.id == id }
    }

    /// Called whenever an account is added or removed, or a record or
    /// signed-in state changes. With one account only the menu is rebuilt,
    /// so single-account badge and popover behavior stay exactly as before.
    func accountsDidChange() {
        rebuildAccountsMenu()
        guard popover != nil else { return }
        rebuildPopoverContent()
        if (accounts.count >= 2) != badgeWasMulti {
            syncBadgeMode()
            updateBadgeFromModel()
            updateMenuBarTooltip()
        } else if accounts.count >= 2 {
            updateBadgeFromModel()
            updateMenuBarTooltip()
        }
    }

    /// Restarts the running refresh timers of secondary accounts so offsets
    /// follow the current account count (index * interval / count). The
    /// primary account (offset 0) keeps its phase.
    func restaggerRefreshTimers() {
        for account in accounts where account.refreshTimer != nil && !account.isPrimary {
            account.startRefreshTimer()
        }
    }

    /// Deletes isolated WebKit stores that no saved, running or pending
    /// account references (left behind by a crash mid-add, an old build, or a
    /// failed removal). Skipped entirely unless the saved account list was
    /// read completely, so a store is never deleted because of a read error.
    func sweepOrphanedDataStores() {
        guard #available(macOS 14.0, *) else { return }
        guard AccountStore.isListFullyReadable else {
            NSLog("%@", "[ClaudeMeter] data store sweep skipped: account list not fully readable")
            return
        }
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, AccountStore.isListFullyReadable else { return }
                var referenced = Set(AccountStore.load().compactMap { $0.storeIdentifier?.lowercased() })
                for account in self.accounts + self.pendingAccounts {
                    if let sid = account.record.storeIdentifier { referenced.insert(sid.lowercased()) }
                }
                let orphans = identifiers.filter { !referenced.contains($0.uuidString.lowercased()) }
                NSLog("%@", "[ClaudeMeter] data store sweep: \(identifiers.count) found, \(orphans.count) orphaned")
                for id in orphans { AccountController.removeDataStore(identifier: id) }
            }
        }
    }

    /// Creates the controllers for every saved account. The primary account
    /// always exists and comes first; secondary accounts need macOS 14 for
    /// their isolated data store and are skipped (left saved) on macOS 13.
    func makeAccountControllers() -> [AccountController] {
        var result = [AccountController(app: self, notifier: notifier,
                                        record: AccountStore.primaryRecord(), dataStore: .default())]
        for record in AccountStore.load() where !record.isPrimary {
            guard #available(macOS 14.0, *) else {
                NSLog("%@", "[ClaudeMeter] account \(record.id) skipped: needs macOS 14 for an isolated data store")
                continue
            }
            guard let sid = record.storeIdentifier, let storeUUID = UUID(uuidString: sid) else {
                // Unusable without its own store (it could never sign in), and
                // invisible in the menu: drop it so nothing lingers.
                AccountStore.remove(id: record.id)
                AccountStore.removeKeys(forAccount: record.id)
                try? FileManager.default.removeItem(at: UsageHistory.fileURL(accountID: record.id))
                NSLog("%@", "[ClaudeMeter] account \(record.id) dropped: missing or invalid store identifier")
                continue
            }
            result.append(AccountController(app: self, notifier: notifier, record: record,
                                            dataStore: WKWebsiteDataStore(forIdentifier: storeUUID)))
        }
        return result
    }

    // MARK: Menu

    /// Account items sit right after "Sign In…". One account: only "Add
    /// Account…" (macOS 14+). Two or more: an "Accounts" submenu listing each
    /// account with Sign In Again / Rename / Remove, plus Add Account. A
    /// signed-out secondary account also gets a top-level "Sign In Again to
    /// <name>…" item, since it never opens a login window on its own.
    func rebuildAccountsMenu() {
        guard let menu = contextMenu else { return }
        for item in accountsMenuItems where item.menu === menu {
            menu.removeItem(item)
        }
        accountsMenuItems = []

        var items: [NSMenuItem] = []
        for account in accounts where !account.isPrimary && account.isSignedOut {
            items.append(accountMenuItem("Sign In Again to \(account.record.displayName)\u{2026}",
                                         #selector(signInAgain(_:)), account))
        }
        if accounts.count >= 2 {
            let parent = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for account in accounts {
                let record = account.record
                var title = record.displayName
                if let tier = Self.planTierDisplayName(slug: record.planTier) { title += " (\(tier))" }
                if account.isSignedOut { title += ", signed out" }
                let accountItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let accountMenu = NSMenu()
                if let detail = record.email ?? record.orgName {
                    let info = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
                    info.isEnabled = false
                    accountMenu.addItem(info)
                    accountMenu.addItem(NSMenuItem.separator())
                }
                accountMenu.addItem(accountMenuItem("Sign In Again\u{2026}", #selector(signInAgain(_:)), account))
                accountMenu.addItem(accountMenuItem("Rename\u{2026}", #selector(renameAccount(_:)), account))
                let position = NSMenuItem(title: "Badge Position", action: nil, keyEquivalent: "")
                let positionMenu = NSMenu()
                for (tag, slot) in [BadgeSlot.left, .right, .hidden].enumerated() {
                    let title = slot == .left ? "Left" : (slot == .right ? "Right" : "Hidden")
                    let item = accountMenuItem(title, #selector(setBadgeSlotFromMenu(_:)), account)
                    item.tag = tag
                    item.state = record.badgeSlot == slot ? .on : .off
                    positionMenu.addItem(item)
                }
                position.submenu = positionMenu
                accountMenu.addItem(position)
                accountMenu.addItem(accountMenuItem("Badge Label (\(record.badgeLabel))\u{2026}", #selector(editBadgeLabel(_:)), account))
                if !account.isPrimary {
                    accountMenu.addItem(accountMenuItem("Remove\u{2026}", #selector(removeAccountFromMenu(_:)), account))
                }
                accountItem.submenu = accountMenu
                submenu.addItem(accountItem)
            }
            if canAddAccounts {
                submenu.addItem(NSMenuItem.separator())
                let add = NSMenuItem(title: "Add Account\u{2026}", action: #selector(addAccount(_:)), keyEquivalent: "")
                add.target = self
                submenu.addItem(add)
            }
            parent.submenu = submenu
            items.append(parent)
        } else if canAddAccounts {
            let add = NSMenuItem(title: "Add Account\u{2026}", action: #selector(addAccount(_:)), keyEquivalent: "")
            add.target = self
            items.append(add)
        }

        var index = signInMenuItem.map { menu.index(of: $0) + 1 } ?? 0
        if index <= 0 || index > menu.numberOfItems { index = min(3, menu.numberOfItems) }
        for item in items {
            menu.insertItem(item, at: index)
            index += 1
        }
        accountsMenuItems = items
    }

    func accountMenuItem(_ title: String, _ action: Selector, _ account: AccountController) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = account.id
        return item
    }

    // MARK: Actions (each runs only from an explicit menu choice)

    @objc func signInAgain(_ sender: NSMenuItem) {
        guard let account = account(withID: sender.representedObject as? String) else { return }
        if popover?.isShown == true { popover.performClose(nil) }
        account.showLoginWindow()
    }

    @objc func renameAccount(_ sender: NSMenuItem) {
        guard let account = account(withID: sender.representedObject as? String) else { return }
        guard let name = promptForText(title: "Rename Account",
                                       message: "Shown in the menu, and in notifications once you have more than one account.",
                                       defaultValue: account.record.displayName,
                                       confirmTitle: "Rename") else { return }
        account.rename(to: name)
    }

    @objc func removeAccountFromMenu(_ sender: NSMenuItem) {
        guard let account = account(withID: sender.representedObject as? String), !account.isPrimary else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove \(account.record.displayName)?"
        alert.informativeText = "ClaudeMeter signs this account out and deletes its usage history and settings. Your claude.ai account itself is not changed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        removeAccount(account)
    }

    @objc func addAccount(_ sender: Any?) {
        guard #available(macOS 14.0, *) else { return }
        // One add at a time: bring the pending sign-in window forward.
        if let pending = pendingAccounts.first {
            pending.showLoginWindow()
            return
        }
        let names = Set((accounts + pendingAccounts).map { $0.record.displayName.lowercased() })
        let suggested = names.contains("work") ? "Account \(accounts.count + 1)" : "Work"
        guard let name = promptForText(title: "Add Account",
                                       message: "Name the account, then sign in to it in the window that opens. It gets its own isolated session, so your other accounts stay signed in.",
                                       defaultValue: suggested,
                                       confirmTitle: "Continue") else { return }
        let controller = beginAddAccount(named: name)
        controller.showLoginWindow()
    }

    // MARK: Add / remove (no UI; also used by QA test hooks)

    /// Creates a not-yet-saved account on a fresh isolated data store. It is
    /// saved and starts metering only after a verified sign-in; closing the
    /// login window first discards it and its store.
    @available(macOS 14.0, *)
    @discardableResult
    func beginAddAccount(named name: String) -> AccountController {
        let storeUUID = UUID()
        // The badge slot is assigned when the add completes (finishAddAccount).
        let record = AccountRecord(id: UUID().uuidString, displayName: name,
                                   badgeLabel: AccountRecord.defaultBadgeLabel(for: name),
                                   badgeSlot: .hidden,
                                   email: nil, orgUUID: nil, orgName: nil, planTier: nil,
                                   orgPinned: false, storeIdentifier: storeUUID.uuidString)
        let controller = AccountController(app: self, notifier: notifier, record: record,
                                           dataStore: WKWebsiteDataStore(forIdentifier: storeUUID))
        controller.isPendingAdd = true
        pendingAccounts.append(controller)
        controller.onLoginWindowClosed = { [weak self, weak controller] succeeded in
            guard let self = self, let controller = controller else { return }
            self.pendingAccounts.removeAll { $0 === controller }
            if succeeded {
                self.finishAddAccount(controller)
            } else {
                NSLog("%@", "[ClaudeMeter] add account cancelled before sign-in; discarding \(controller.id)")
                self.discardAccount(controller)
            }
        }
        NSLog("%@", "[ClaudeMeter] add account started: \(record.id)")
        return controller
    }

    /// Saves a pending account and starts metering it.
    func finishAddAccount(_ controller: AccountController) {
        // Slot decided now, not at start, so two adds can never both take Right.
        let rightTaken = accounts.contains { $0.record.badgeSlot == .right }
        controller.updateRecord { $0.badgeSlot = rightTaken ? .hidden : .right }
        controller.isPendingAdd = false
        controller.persistRecord()
        accounts.append(controller)
        NSLog("%@", "[ClaudeMeter] account added: \(controller.id) slot=\(controller.record.badgeSlot.rawValue) accounts=\(accounts.count)")
        restaggerRefreshTimers()
        if popover?.isShown == true || showMenuBarBadge {
            controller.startRefreshTimer()
        }
        accountsDidChange()
    }

    /// Removes a secondary account completely: stops it, deletes its saved
    /// record, its namespaced UserDefaults keys (exact ID segment), its
    /// history file and its isolated WebKit data store.
    func removeAccount(_ account: AccountController) {
        guard !account.isPrimary else { return }
        let id = account.id
        // Stop it first so no in-flight fetch writes history or keys back.
        account.tearDown()
        accounts.removeAll { $0 === account }
        AccountStore.remove(id: id)
        let removedKeys = AccountStore.removeKeys(forAccount: id)
        let historyURL = UsageHistory.fileURL(accountID: id)
        let hadHistory = FileManager.default.fileExists(atPath: historyURL.path)
        try? FileManager.default.removeItem(at: historyURL)
        notifier.removeDeliveredNotifications(forAccount: id)
        NSLog("%@", "[ClaudeMeter] account removed: \(id) keys=\(removedKeys) history=\(hadHistory ? "deleted" : "none") accounts=\(accounts.count)")
        discardAccount(account)
        restaggerRefreshTimers()
        accountsDidChange()
    }

    /// Tears a controller down and deletes its isolated data store once
    /// WebKit has released it.
    private func discardAccount(_ account: AccountController) {
        let storeID = account.record.storeIdentifier.flatMap { UUID(uuidString: $0) }
        account.tearDown()
        guard !account.isPrimary, let uuid = storeID else { return }
        if #available(macOS 14.0, *) {
            // Give WebKit a moment to drop the web views that used the store.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AccountController.removeDataStore(identifier: uuid)
            }
        }
    }

    // MARK: Dialogs

    func promptForText(title: String, message: String, defaultValue: String, confirmTitle: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(40))
    }

    /// Org picker shown after a verified sign-in that returned several orgs.
    /// Always returns one of `orgs` (the preselected one if the user just
    /// confirms).
    /// `preselect` (the pinned org on Sign In Again) wins; otherwise a Team
    /// or Enterprise org is preselected, since extra accounts are usually work
    /// accounts. Orgs another account already meters are marked.
    func pickOrganization(_ orgs: [OrgListResponse.Org], for account: AccountController,
                          preselect: String? = nil) -> OrgListResponse.Org {
        func isWorkOrg(_ org: OrgListResponse.Org) -> Bool {
            let tier = (org.rate_limit_tier ?? "").lowercased()
            let caps = (org.capabilities ?? []).map { $0.lowercased() }
            return tier.contains("team") || tier.contains("enterprise")
                || caps.contains { $0.contains("team") || $0.contains("enterprise") }
        }
        let preferred = preselect.flatMap { p in orgs.firstIndex { $0.uuid == p } }
            ?? orgs.firstIndex(where: isWorkOrg) ?? 0
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Choose an organization for \(account.record.displayName)"
        alert.informativeText = "This sign-in belongs to several organizations. ClaudeMeter meters the one you choose; you can change it later with Sign In Again."
        alert.addButton(withTitle: "Use This Organization")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        for org in orgs {
            var title = org.name ?? "Organization"
            if let tier = Self.planTierDisplayName(slug: org.rate_limit_tier) { title += " (\(tier))" }
            if let other = accounts.first(where: { $0 !== account && $0.record.orgUUID == org.uuid }) {
                title += ", already metered as \(other.record.displayName)"
            }
            popup.addItem(withTitle: title)
        }
        popup.selectItem(at: preferred)
        alert.accessoryView = popup
        alert.runModal()
        let index = popup.indexOfSelectedItem
        return orgs.indices.contains(index) ? orgs[index] : orgs[preferred]
    }
}

// MARK: - Accounts: combined badge and popover

extension AppDelegate {
    // MARK: Badge slots

    /// At most one account per badge slot; extra claimants become Hidden.
    func normalizeBadgeSlots() {
        var taken = Set<BadgeSlot>()
        for account in accounts {
            let slot = account.record.badgeSlot
            guard slot != .hidden else { continue }
            if taken.contains(slot) {
                account.updateRecord { $0.badgeSlot = .hidden }
                NSLog("%@", "[ClaudeMeter] badge slot \(slot.rawValue) already taken; \(account.id) set to hidden")
            } else {
                taken.insert(slot)
            }
        }
    }

    /// Moves an account to a slot. A Left/Right slot holds one account: its
    /// previous occupant moves to Hidden.
    func setBadgeSlot(_ slot: BadgeSlot, for account: AccountController) {
        if slot != .hidden {
            for other in accounts where other !== account && other.record.badgeSlot == slot {
                other.updateRecord { $0.badgeSlot = .hidden }
            }
        }
        account.updateRecord { $0.badgeSlot = slot }
        NSLog("%@", "[ClaudeMeter] badge slot: \(account.id) -> \(slot.rawValue)")
    }

    /// Sets a 1 to 3 character badge label (trimmed). Returns false if empty.
    @discardableResult
    func setBadgeLabel(_ text: String, for account: AccountController) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let label = String(trimmed.prefix(3))
        account.updateRecord { $0.badgeLabel = label }
        return true
    }

    /// Accounts shown in the badge, left then right. One account: that
    /// account (no label). Several: the Left and Right slot holders; if both
    /// slots are Hidden, the primary account as if it held Left, so the badge
    /// never goes blank while "Show Usage in Menu Bar" is on.
    func badgeAccounts() -> [AccountController] {
        guard accounts.count >= 2 else { return Array(accounts.prefix(1)) }
        let left = accounts.first { $0.record.badgeSlot == .left }
        let right = accounts.first { $0.record.badgeSlot == .right }
        let shown = [left, right].compactMap { $0 }
        return shown.isEmpty ? [accounts[0]] : shown
    }

    func cachedBadgeSideText(for account: AccountController) -> String {
        let cached = UserDefaults.standard.integer(forKey: account.lastBadgePercentageKey)
        return cached > 0 ? "\(cached)%" : "\u{2014}%"
    }

    /// Two or more accounts: refresh each shown side from its own account's
    /// model (or its own XPath fallback, never for a pinned org), keeping
    /// that side's last value otherwise.
    func updateMultiAccountBadge() {
        for account in badgeAccounts() {
            let id = account.id
            if account.isSignedOut { continue }
            if let pct = account.sessionPercentage(from: account.latestSections) {
                badgeSideText[id] = "\(pct)%"
                UserDefaults.standard.set(pct, forKey: account.lastBadgePercentageKey)
                continue
            }
            if badgeSideText[id] == nil { badgeSideText[id] = cachedBadgeSideText(for: account) }
            guard !account.record.orgPinned else { continue }
            account.webView.evaluateJavaScript(Self.scrapeSessionPercentageJS) { [weak self, weak account] result, _ in
                guard let self = self, let account = account, !account.isSignedOut,
                      self.showMenuBarBadge, self.popover?.isShown != true,
                      self.accounts.count >= 2, let pct = result as? Int else { return }
                self.badgeSideText[account.id] = "\(pct)%"
                UserDefaults.standard.set(pct, forKey: account.lastBadgePercentageKey)
                self.renderMultiAccountBadge(reason: "XPath fallback scrape")
            }
        }
        renderMultiAccountBadge(reason: "model meter labeled current session")
    }

    /// "W 47%" with one shown side, "P 47% | W 12%" with two (left first).
    /// A signed-out side reads "W --".
    func renderMultiAccountBadge(reason: String) {
        let parts = badgeAccounts().map { account -> String in
            let value = account.isSignedOut ? "--" : (badgeSideText[account.id] ?? cachedBadgeSideText(for: account))
            return "\(account.record.badgeLabel) \(value)"
        }
        setBadgeTitle(parts.joined(separator: " | "), reason: reason)
    }

    /// Restores the badge from cached values (launch, badge re-enabled, or a
    /// switch between one and several accounts).
    func restoreCachedBadge() {
        badgeWasMulti = accounts.count >= 2
        if accounts.count >= 2 {
            for account in badgeAccounts() { badgeSideText[account.id] = cachedBadgeSideText(for: account) }
            renderMultiAccountBadge(reason: "applyBadgeVisibility cached=multi")
        } else {
            let cached = accounts.first.map { UserDefaults.standard.integer(forKey: $0.lastBadgePercentageKey) } ?? 0
            setBadgeTitle(cached > 0 ? "\(cached)%" : "\u{2014}%", reason: "applyBadgeVisibility cached=\(cached)")
        }
    }

    /// After the account count crosses between one and several, re-render
    /// the badge in the matching form (not while the popover is open).
    func syncBadgeMode() {
        guard showMenuBarBadge, popover?.isShown != true, (accounts.count >= 2) != badgeWasMulti else { return }
        restoreCachedBadge()
    }

    /// An account's empty-scrape streak reached the threshold: blank its side.
    func badgeAccountFailed(_ account: AccountController, reason: String) {
        if accounts.count >= 2 {
            guard badgeAccounts().contains(where: { $0 === account }) else { return }
            badgeSideText[account.id] = "\u{2014}%"
            renderMultiAccountBadge(reason: reason)
        } else if account === accounts.first {
            setBadgeTitle("\u{2014}%", reason: reason)
        }
    }

    /// Two or more accounts: one block per account in the menu-bar tooltip.
    func multiAccountTooltip() -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "a"; f.pmSymbol = "p"
        var lines: [String] = []
        for account in accounts {
            let name = account.record.displayName
            if account.isSignedOut {
                lines.append("\(name): signed out")
                continue
            }
            var parts: [String] = []
            if let s = account.sessionPercentage(from: account.latestSections) { parts.append("session \(s)%") }
            if let w = account.weeklyPercentage(from: account.latestSections) { parts.append("weekly \(w)%") }
            lines.append("\(name): " + (parts.isEmpty ? "no usage data yet" : parts.joined(separator: " · ")))
            let samples = account.history.samples
            if let peak = samples.max(by: { $0.s < $1.s }) {
                let avg = Int((Double(samples.reduce(0) { $0 + $1.s }) / Double(samples.count)).rounded())
                let peakTime = f.string(from: Date(timeIntervalSince1970: peak.t)).lowercased()
                lines.append("  Peak: \(peak.s)% at \(peakTime) · 24h avg: \(avg)%")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Popover

    /// Clamps and animates the popover to a content height.
    func applyPopoverContentHeight(_ height: CGFloat) {
        // Use as much of the screen as macOS permits. NSPopover hard-caps
        // around (visibleFrame - small margin) on its own; we just need to
        // not under-clamp ahead of it. Floor at 1200 so smaller screens
        // still get a generously tall popover.
        let screenMax = (NSScreen.main?.visibleFrame.height ?? 1200) - 40
        let ceiling = max(1200, screenMax)
        let clamped = min(max(height, 120), ceiling)
        let current = popover.contentSize.height
        // Only animate if the height changed meaningfully: sub-pixel layout
        // rounding differences would otherwise cause the popover to flicker.
        guard abs(clamped - current) > 2 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.allowsImplicitAnimation = true
            self.popover.contentSize = NSSize(width: 400, height: clamped)
        }
    }

    /// Each account's own usage view. The primary account's is `usageView`
    /// (the whole popover with one account); others are created on demand.
    func usageView(for account: AccountController) -> UsageContentView {
        if account.isPrimary, let view = usageView { return view }
        if let view = accountViews[account.id] { return view }
        let view = UsageContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.planTierDisplayName = Self.planTierDisplayName(slug: account.cachedPlanTier)
        view.showBurnRate = showBurnRate
        view.showSparkline = showSparkline
        account.usageView = view
        accountViews[account.id] = view
        account.renderLatest()
        return view
    }

    /// The usage views currently in the popover.
    var activeUsageViews: [UsageContentView] {
        guard accounts.count >= 2 else { return usageView.map { [$0] } ?? [] }
        return accounts.map { usageView(for: $0) }
    }

    /// One account: the popover is exactly that account's usage view, as
    /// before. Two or more: the stacked multi-account view.
    func rebuildPopoverContent() {
        guard let vc = popover?.contentViewController, let primaryView = usageView else { return }
        if accounts.count >= 2 {
            let multi: MultiAccountUsageView
            if let existing = multiAccountView {
                multi = existing
            } else {
                multi = MultiAccountUsageView(frame: NSRect(x: 0, y: 0, width: 400, height: popover.contentSize.height))
                multi.onContentSizeChanged = { [weak self] height in self?.applyPopoverContentHeight(height) }
                multi.onSignInAgain = { [weak self] id in
                    guard let self = self, let account = self.account(withID: id) else { return }
                    if self.popover.isShown { self.popover.performClose(nil) }
                    account.showLoginWindow()
                }
                multiAccountView = multi
            }
            if vc.view !== multi { vc.view = multi }
            let entries = accounts.map { account -> MultiAccountUsageView.Entry in
                let record = account.record
                let tier = Self.planTierDisplayName(slug: record.planTier)
                let view = usageView(for: account)
                view.planTierDisplayName = tier
                let detail = [record.email ?? record.orgName, tier].compactMap { $0 }.joined(separator: " · ")
                return MultiAccountUsageView.Entry(accountID: account.id, title: record.displayName,
                                                   detail: detail.isEmpty ? nil : detail,
                                                   signedOut: account.isSignedOut, usageView: view)
            }
            multi.reload(entries)
        } else if let multi = multiAccountView {
            multi.detachAll()
            multiAccountView = nil
            primaryView.isEmbedded = false
            primaryView.isHidden = false
            primaryView.translatesAutoresizingMaskIntoConstraints = true
            primaryView.frame = NSRect(x: 0, y: 0, width: 400, height: popover.contentSize.height)
            primaryView.onContentSizeChanged = { [weak self] height in self?.applyPopoverContentHeight(height) }
            vc.view = primaryView
            applyPopoverContentHeight(primaryView.skeletonHeight)
        }
        let live = Set(accounts.map { $0.id })
        accountViews = accountViews.filter { live.contains($0.key) }
    }

    // MARK: Menu actions for the badge

    @objc func setBadgeSlotFromMenu(_ sender: NSMenuItem) {
        guard let account = account(withID: sender.representedObject as? String) else { return }
        let slots: [BadgeSlot] = [.left, .right, .hidden]
        guard slots.indices.contains(sender.tag) else { return }
        setBadgeSlot(slots[sender.tag], for: account)
    }

    @objc func editBadgeLabel(_ sender: NSMenuItem) {
        guard let account = account(withID: sender.representedObject as? String) else { return }
        guard let text = promptForText(title: "Badge Label",
                                       message: "One to three characters shown before this account's percentage in the menu bar.",
                                       defaultValue: account.record.badgeLabel,
                                       confirmTitle: "Save") else { return }
        setBadgeLabel(text, for: account)
    }
}

// MARK: - Account Controller

/// Per-account metering engine. Owns one claude.ai session end to end: the
/// off-screen WKWebView and its cookie store, the fallback login window and
/// OAuth popups, the refresh timer, the JSON circuit breaker and empty-scrape
/// streak, the resolved org and plan tier, the latest sections, history and
/// forecast. It is the navigation and UI delegate for every web view it
/// creates (background, login and OAuth popups) and the window delegate for
/// its login window; OAuth popup windows have no window delegate. App-wide UI
/// (status item, popover, menu, preferences) stays on AppDelegate, reached
/// through `app`.
final class AccountController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    /// AppDelegate owns every AccountController and lives for the whole
    /// process, so this back-reference can never dangle.
    unowned let app: AppDelegate
    /// The single shared notifier (also the UNUserNotificationCenter delegate).
    /// Stored non-optional so the notifier evaluate call keeps exactly one call site,
    /// inside distributeFetchResult (static-audit check 16).
    let notifier: ThresholdNotifier
    /// The popover section this account renders into. Owned by the popover's
    /// view controller.
    weak var usageView: UsageContentView?

    let webView: WKWebView
    /// WebKit data store holding this account's claude.ai session: the
    /// default store for the primary account, an identifier-keyed store
    /// (macOS 14+) for every other account. Login windows and OAuth popups
    /// use it too.
    let dataStore: WKWebsiteDataStore
    var refreshTimer: Timer?
    var lastRefreshDate: Date?
    // Counts background refreshes; every 30th does a full WebView reload.
    var refreshCycleCount: Int = 0
    // v2.7: latest session forecast, read by the menu-bar tooltip.
    var lastSessionForecast: UsageForecast?
    // Latest render inputs, replayed into a usage view created later.
    var lastWeeklyForecast: UsageForecast?
    var lastSessionResetAt: Date?
    var lastWeeklyResetAt: Date?

    /// Persisted, non-secret description of this account (id, label, badge
    /// slot, org, plan tier, store identifier). Saved through AccountStore.
    private(set) var record: AccountRecord
    var id: String { record.id }

    // Shared data store — populated by every scrape, read by badge and popover
    var latestSections: [UsageSection] = []
    var history: UsageHistory

    // Empty-scrape streak. Transient empties happen during normal page renders
    // (React mid-update), so a single empty must NOT clear the badge or popover.
    // Only a sustained streak indicates a real failure (page DOM changed,
    // network broke, scraper no longer matches).
    var consecutiveEmptyScrapes: Int = 0
    static let emptyScrapeFailureThreshold = 3

    // JSON-primary fetch state. Org and tier live on the account record.
    var cachedOrgUUID: String? {
        get { record.orgUUID }
        set { record.orgUUID = newValue }
    }
    var cachedPlanTier: String? {
        get { record.planTier }
        set { record.planTier = newValue }
    }
    var jsonFetchInFlight: Bool = false
    var jsonConsecutiveFailures: Int = 0
    var jsonCircuitOpen: Bool = false
    var jsonCircuitOpenedAt: Date?
    static let jsonFailureCircuitBreaker = 5
    // Background WebView is process-suspended when the popover is closed, so a
    // permanently-open JSON circuit means DOM scrapes return stale page data
    // until the next ~hourly full reload. Auto-reset gives JSON another shot.
    static let jsonCircuitResetInterval: TimeInterval = 30 * 60

    // Fallback login window (email/magic-link in WKWebView)
    var loginWindow: NSWindow?
    var loginWebView: WKWebView?

    // OAuth popup windows
    var popupWindows: [NSWindow] = []

    // Track whether we've already tried the desktop import for this launch
    var hasAttemptedDesktopImport = false

    /// True when the background page or the usage API says this account's
    /// session is gone. A secondary account then waits for the user to pick
    /// "Sign In Again"; nothing opens on its own.
    private(set) var isSignedOut = false

    // Login verification: /api/organizations must return 200 with at least
    // one org, checked after each login-page load and every 4s.
    private var loginCheckTimer: Timer?
    private var loginCheckInFlight = false
    private var loginSucceeded = false
    private var lastLoginCheckStatus: Int?
    // Signed-out confirmation and slow background re-probe (secondaries).
    private var signInProbeInFlight = false
    private var signedOutProbeTimer: Timer?
    private var pageRetryUsed = false
    static let signedOutProbeInterval: TimeInterval = 15 * 60
    /// Called once when the login window closes: true after a verified
    /// sign-in, false when the user closed it first.
    var onLoginWindowClosed: ((Bool) -> Void)?
    /// An account being added: not saved, not in `app.accounts` yet.
    var isPendingAdd = false
    private var isTornDown = false

    var isPrimary: Bool { record.isPrimary }

    init(app: AppDelegate, notifier: ThresholdNotifier, record: AccountRecord, dataStore: WKWebsiteDataStore) {
        self.app = app
        self.notifier = notifier
        self.record = record
        self.dataStore = dataStore
        self.history = UsageHistory.loadFromDisk(accountID: record.id)
        // WKWebView is kept off-screen for data scraping only
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = AppDelegate.safariUA
    }

    // MARK: - Per-account keys

    var lastFetchPathKey: String { AccountKeys.key(AppDelegate.lastFetchPathKey, id) }
    var lastBadgePercentageKey: String { AccountKeys.key(AppDelegate.lastBadgePercentageKey, id) }

    /// Saves this account's record (org, tier, labels) to UserDefaults. The
    /// controller is the record's only writer: every edit (org discovery,
    /// rename, sign-in) goes through it, and AccountStore.upsert replaces only
    /// this record, so edits to different accounts never clobber each other.
    /// A pending (not yet added) account is not saved.
    func persistRecord() {
        guard !isPendingAdd, !isTornDown else { return }
        AccountStore.upsert(record)
        app.accountsDidChange()
    }

    /// Applies an edit to the record and saves it.
    func updateRecord(_ change: (inout AccountRecord) -> Void) {
        change(&record)
        persistRecord()
    }

    /// Renames the account; a badge label still at its default follows the name.
    func rename(to name: String) {
        updateRecord { r in
            if r.badgeLabel == AccountRecord.defaultBadgeLabel(for: r.displayName) {
                r.badgeLabel = AccountRecord.defaultBadgeLabel(for: name)
            }
            r.displayName = name
        }
        NSLog("%@", "[ClaudeMeter] account renamed: \(id)")
    }

    func setSignedOut(_ signedOut: Bool, reason: String) {
        guard signedOut != isSignedOut else { return }
        isSignedOut = signedOut
        NSLog("%@", "[ClaudeMeter] account \(id) \(signedOut ? "signed out" : "signed in") (\(reason))")
        if signedOut && !isPrimary {
            startSignedOutProbe()
        } else {
            signedOutProbeTimer?.invalidate()
            signedOutProbeTimer = nil
        }
        if !isPendingAdd { app.accountsDidChange() }
    }

    // MARK: - Signed-out confirmation (secondary accounts)

    enum SignInVerdict { case signedIn, signedOut(String), unknown }

    /// Reads an /api/organizations answer: 401/403 means signed out; 2xx
    /// listing the pinned org (any org when unpinned) means signed in; 2xx
    /// without the pinned org means signed out (the org is gone, so Sign In
    /// Again lets the user choose; background code never re-pins); anything
    /// else is inconclusive.
    func signInVerdict(status: Int, orgs: [OrgListResponse.Org]?) -> SignInVerdict {
        if status == 401 || status == 403 { return .signedOut("organizations HTTP \(status)") }
        guard (200..<300).contains(status), let orgs = orgs else { return .unknown }
        if record.orgPinned, let pinned = record.orgUUID {
            return orgs.contains { $0.uuid == pinned } ? .signedIn : .signedOut("pinned org no longer listed")
        }
        return orgs.isEmpty ? .signedOut("no organizations") : .signedIn
    }

    /// One /api/organizations call with this account's cookies (no windows,
    /// no alerts), reported as a verdict.
    func probeSignIn(_ completion: @escaping (SignInVerdict) -> Void) {
        guard !signInProbeInFlight, !isTornDown else { return }
        signInProbeInFlight = true
        copyCookiesToSession(logCount: false) { [weak self] session in
            guard let self = self else { session.finishTasksAndInvalidate(); return }
            self.requestOrgList(session: session, context: "signInProbe", quiet: true) { [weak self] status, orgs in
                session.finishTasksAndInvalidate()
                guard let self = self, !self.isTornDown else { return }
                self.signInProbeInFlight = false
                completion(self.signInVerdict(status: status, orgs: orgs))
            }
        }
    }

    /// A secondary account is marked signed out only after the API agrees,
    /// so one transient 403 or an odd page landing cannot sign it out.
    func confirmSignedOut(reason: String) {
        guard !isPrimary, !isSignedOut else { return }
        probeSignIn { [weak self] verdict in
            guard let self = self else { return }
            switch verdict {
            case .signedOut(let why):
                self.setSignedOut(true, reason: "\(reason); \(why)")
            case .signedIn:
                NSLog("%@", "[ClaudeMeter] account \(self.id): \(reason), but organizations still answer; treating as transient")
                // A page that wandered off the usage page: one reload later.
                if !self.pageRetryUsed, self.webView.url?.absoluteString.contains("/settings/usage") != true {
                    self.pageRetryUsed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                        guard let self = self, !self.isTornDown else { return }
                        self.webView.load(URLRequest(url: AppDelegate.usageURL))
                    }
                }
            case .unknown:
                NSLog("%@", "[ClaudeMeter] account \(self.id): \(reason), sign-in check inconclusive; no change")
            }
        }
    }

    /// Slow re-check while a secondary account is signed out (every 15 min,
    /// staggered; API only). A false "signed out" heals on its own.
    private func startSignedOutProbe() {
        signedOutProbeTimer?.invalidate()
        signedOutProbeTimer = Timer.scheduledTimer(withTimeInterval: Self.signedOutProbeInterval, repeats: true) { [weak self] _ in
            self?.runSignedOutProbe()
        }
        signedOutProbeTimer?.tolerance = 60
        signedOutProbeTimer?.fireDate = Date().addingTimeInterval(Self.signedOutProbeInterval + Double(staggerIndex) * 30)
    }

    func runSignedOutProbe() {
        guard isSignedOut, !isPrimary, loginWindow == nil else { return }
        probeSignIn { [weak self] verdict in
            guard let self = self, self.isSignedOut, case .signedIn = verdict else { return }
            self.setSignedOut(false, reason: "background probe: organizations answer again")
            self.webView.load(URLRequest(url: AppDelegate.usageURL))
        }
    }

    // MARK: - Staggering

    /// Position among the metered accounts (0 for the primary account).
    var staggerIndex: Int { app.accounts.firstIndex { $0 === self } ?? 0 }

    /// Runs `work` now for the first account and 2s later per position for
    /// the others, so accounts never hit claude.ai in the same second.
    func staggered(_ work: @escaping () -> Void) {
        let delay = Double(staggerIndex) * 2.0
        if delay <= 0 {
            work()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.isTornDown else { return }
                work()
            }
        }
    }

    /// Pushes the latest data into a usage view created after it arrived.
    func renderLatest() {
        guard let view = usageView, !latestSections.isEmpty else { return }
        view.update(sections: latestSections,
                    sessionForecast: lastSessionForecast,
                    weeklyForecast: lastWeeklyForecast,
                    sessionResetAt: lastSessionResetAt,
                    weeklyResetAt: lastWeeklyResetAt,
                    history: history)
        view.setStatusFresh(true)
    }

    /// Import cookies and start loading. The primary account imports Claude
    /// Desktop's cookies first and loads whether or not that worked; a login
    /// page then routes to the login window through didFinish. Secondary
    /// accounts load straight from their own store (Claude Desktop's session
    /// belongs to the primary account only).
    func start() {
        hasAttemptedDesktopImport = true
        guard isPrimary else {
            staggered { [weak self] in
                self?.webView.load(URLRequest(url: AppDelegate.usageURL))
            }
            return
        }
        importFromClaudeDesktop { [weak self] success in
            guard let self = self else { return }
            self.webView.load(URLRequest(url: AppDelegate.usageURL))
        }
    }

    /// Stops all activity before the account is discarded: timers, windows
    /// and page loads. Afterwards nothing reloads or saves.
    func tearDown() {
        isTornDown = true
        stopRefreshTimer()
        signedOutProbeTimer?.invalidate()
        signedOutProbeTimer = nil
        loginCheckTimer?.invalidate()
        loginCheckTimer = nil
        onLoginWindowClosed = nil
        loginWindow?.close()
        for window in popupWindows { window.close() }
        popupWindows.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    /// Deletes an isolated account's WebKit data store (cookies, storage).
    /// Retries while WebKit still has it in use.
    @available(macOS 14.0, *)
    static func removeDataStore(identifier: UUID, attempt: Int = 1) {
        WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
            DispatchQueue.main.async {
                if let error = error {
                    NSLog("%@", "[ClaudeMeter] data store removal attempt \(attempt) failed: \(error.localizedDescription)")
                    if attempt < 4 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            removeDataStore(identifier: identifier, attempt: attempt + 1)
                        }
                    }
                } else {
                    NSLog("%@", "[ClaudeMeter] data store removed (attempt \(attempt))")
                }
            }
        }
    }

    // MARK: - Claude Desktop Cookie Import

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
        window.title = isPrimary ? "Sign in to Claude" : "Sign in to Claude: \(record.displayName)"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let loginConfig = WKWebViewConfiguration()
        loginConfig.websiteDataStore = dataStore

        let lw = WKWebView(frame: window.contentView!.bounds, configuration: loginConfig)
        lw.autoresizingMask = [.width, .height]
        lw.navigationDelegate = self
        lw.uiDelegate = self
        lw.customUserAgent = AppDelegate.safariUA
        lw.load(URLRequest(url: AppDelegate.loginURL))

        window.contentView?.addSubview(lw)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        loginWebView = lw
        loginWindow = window
        loginSucceeded = false
        lastLoginCheckStatus = nil
        loginCheckTimer?.invalidate()
        loginCheckTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.checkLoginSucceeded()
        }
    }

    /// Closes the login window; windowWillClose resets state and reloads.
    func closeLoginWindow() {
        loginWindow?.close()
    }

    /// Sign-in counts as done only when /api/organizations, called with this
    /// account's cookies, returns 200 with at least one org. A URL guess is
    /// not enough: SSO flows pass through intermediate claude.ai pages.
    func checkLoginSucceeded() {
        guard loginWindow != nil, !loginSucceeded, !loginCheckInFlight, !isTornDown else { return }
        loginCheckInFlight = true
        copyCookiesToSession(logCount: false) { [weak self] session in
            guard let self = self else { session.finishTasksAndInvalidate(); return }
            self.requestOrgList(session: session, context: "loginCheck", quiet: true) { [weak self] status, orgs in
                session.finishTasksAndInvalidate()
                guard let self = self else { return }
                self.loginCheckInFlight = false
                // Log state changes only (this runs every 4s).
                if status != self.lastLoginCheckStatus {
                    self.lastLoginCheckStatus = status
                    NSLog("%@", "[ClaudeMeter] loginCheck for account \(self.id): HTTP \(status), \(orgs?.count ?? 0) orgs")
                }
                guard self.loginWindow != nil, !self.loginSucceeded, (200..<300).contains(status) else { return }
                let orgList = orgs ?? []
                // The primary account also accepts a 2xx with an undecodable
                // org list once the login page sits on a claude.ai non-login
                // page, so a shape change cannot keep the window open forever.
                let pageLooksSignedIn: Bool = {
                    guard let url = self.loginWebView?.url, let host = url.host?.lowercased() else { return false }
                    let onClaude = host == "claude.ai" || host.hasSuffix(".claude.ai")
                    return onClaude && !self.isLoginURL(url.absoluteString)
                }()
                if !orgList.isEmpty || (self.isPrimary && pageLooksSignedIn) {
                    self.completeLogin(orgs: orgList)
                }
            }
        }
    }

    /// Verified sign-in. Secondary accounts pin their org: the pinned org if
    /// it is still listed, else the only org, else the user's pick. The
    /// primary account keeps today's automatic org selection.
    private func completeLogin(orgs: [OrgListResponse.Org]) {
        loginSucceeded = true
        loginCheckTimer?.invalidate()
        loginCheckTimer = nil
        NSLog("%@", "[ClaudeMeter] login verified for account \(id): \(orgs.count) org(s)")
        if !isPrimary {
            // Several orgs: always ask, with the pinned org preselected. A
            // pinned org that disappeared is never silently replaced: ask even
            // if only one org is left. One org and nothing pinned: take it.
            let pinned = record.orgPinned ? record.orgUUID : nil
            let pinnedListed = pinned.map { p in orgs.contains { $0.uuid == p } } ?? false
            let chosen: OrgListResponse.Org
            if orgs.count == 1 && (pinned == nil || pinnedListed) {
                chosen = orgs[0]
            } else {
                chosen = app.pickOrganization(orgs, for: self, preselect: pinnedListed ? pinned : nil)
            }
            updateRecord { r in
                r.orgUUID = chosen.uuid
                r.orgName = chosen.name ?? r.orgName
                r.planTier = chosen.rate_limit_tier ?? r.planTier
                r.orgPinned = true
            }
        }
        jsonConsecutiveFailures = 0
        jsonCircuitOpen = false
        jsonCircuitOpenedAt = nil
        setSignedOut(false, reason: "login verified")
        loginWindow?.close()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString else { return }

        // Secondary accounts: a sign-in page or any page outside claude.ai
        // (an SSO identity provider) is a hint only; the API confirms before
        // the account is marked signed out. They never open a window on
        // their own; the menu offers "Sign In Again to <name>" instead.
        if webView === self.webView && !isPrimary && looksSignedOut(url) {
            confirmSignedOut(reason: "background page left the usage page for a sign-in page")
            return
        }

        // Popover hit a login page → show login window (desktop import already attempted at startup)
        if webView === self.webView && isLoginURL(url) {
            setSignedOut(true, reason: "background page reached a sign-in page")
            if !hasAttemptedDesktopImport {
                hasAttemptedDesktopImport = true
                importFromClaudeDesktop { [weak self] success in
                    guard let self = self else { return }
                    if success {
                        self.webView.load(URLRequest(url: AppDelegate.usageURL))
                    } else {
                        if self.app.popover.isShown { self.app.popover.performClose(nil) }
                        self.showLoginWindow()
                    }
                }
                return
            }
            if app.popover.isShown { app.popover.performClose(nil) }
            showLoginWindow()
            return
        }

        // Login WebView finished a page: verify sign-in through the API.
        if webView === loginWebView {
            checkLoginSucceeded()
            return
        }

        if webView === self.webView {
            pageRetryUsed = false
            lastRefreshDate = Date()
            usageView?.setStatusFresh(true)
            // Scrape immediately, then again after React renders
            scrapeAndDistribute()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self else { return }
                self.scrapeAndDistribute()
                // Ensure refresh timer is running after initial page load
                if self.refreshTimer == nil && (self.app.popover?.isShown == true || self.app.showMenuBarBadge) {
                    self.startRefreshTimer()
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
        popupWindow.delegate = self   // so a closed popup leaves popupWindows

        let popupWebView = WKWebView(frame: popupWindow.contentView!.bounds, configuration: configuration)
        popupWebView.autoresizingMask = [.width, .height]
        popupWebView.navigationDelegate = self
        popupWebView.uiDelegate = self
        popupWebView.customUserAgent = AppDelegate.safariUA

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
            let succeeded = loginSucceeded
            loginCheckTimer?.invalidate()
            loginCheckTimer = nil
            loginWindow = nil
            loginWebView = nil
            let callback = onLoginWindowClosed
            onLoginWindowClosed = nil
            callback?(succeeded)
            // A cancelled add is discarded by the callback; nothing to load.
            if !isTornDown && (succeeded || !isPendingAdd) {
                webView.load(URLRequest(url: AppDelegate.usageURL))
            }
        }
        popupWindows.removeAll { $0 === window }
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
                    self?.scrapeAndDistribute()
                }
            } else {
                self?.gracefulReload()
            }
        }
    }

    /// Full page reload.
    func gracefulReload() {
        usageView?.setStatusLoading()
        webView.load(URLRequest(url: AppDelegate.usageURL))
    }

    // MARK: - Polling (Unified Adaptive Timer)

    /// The effective refresh interval depends on popover state.
    var activeRefreshInterval: TimeInterval {
        if app.popover?.isShown == true {
            return app.statusFreshnessInterval   // fast (6s default)
        } else {
            return app.badgeRefreshInterval       // slow (120s default)
        }
    }

    /// Repeating refresh timer. Accounts are staggered: account i of n first
    /// fires after i * interval / n (the primary account, i = 0, after one
    /// full interval as before), so two accounts never refresh together.
    func startRefreshTimer() {
        refreshTimer?.invalidate()
        guard !isTornDown else { return }
        let interval = activeRefreshInterval
        let count = max(app.accounts.count, 1)
        let offset = interval * Double(staggerIndex) / Double(count)
        if offset > 0 {
            NSLog("[ClaudeMeter] startRefreshTimer: interval=\(interval)s, popoverOpen=\(app.popover?.isShown == true), account=\(id) offset=\(Int(offset))s")
        } else {
            NSLog("[ClaudeMeter] startRefreshTimer: interval=\(interval)s, popoverOpen=\(app.popover?.isShown == true)")
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.unifiedRefresh()
        }
        refreshTimer?.tolerance = interval * 0.1
        if offset > 0 {
            refreshTimer?.fireDate = Date().addingTimeInterval(offset)
        }
    }

    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Unified refresh: clicks the site's refresh button, then scrapes all data.
    /// Adapts behavior based on whether the popover is open or closed.
    func unifiedRefresh() {
        guard !isTornDown else { return }
        // A signed-out secondary account stays idle until the user signs in
        // again (no repeated requests with a dead session).
        if isSignedOut && !isPrimary { return }
        guard let url = webView.url?.absoluteString, url.contains("/settings/usage") else { return }

        let popoverOpen = app.popover?.isShown == true

        // When popover is closed, only refresh if badge is enabled
        if !popoverOpen && !app.showMenuBarBadge { return }

        // Periodic full WebView reload to prevent unbounded memory growth
        // (only relevant when running in background badge mode)
        if !popoverOpen {
            refreshCycleCount += 1
            if refreshCycleCount >= 30 {
                refreshCycleCount = 0
                NSLog("[ClaudeMeter] unifiedRefresh: periodic full reload to reclaim WebView memory")
                webView.load(URLRequest(url: AppDelegate.usageURL))
                return
            }
        }

        // Skip the in-page Refresh-button click when JSON is the active path:
        // JSON hits Anthropic's API directly and doesn't depend on the page's
        // own React state, so the click + 1.5s wait is dead weight (and the
        // button selector is currently brittle, returning 'not_found').
        let lastPath = UserDefaults.standard.string(forKey: lastFetchPathKey) ?? ""
        if lastPath == "json" && !jsonCircuitOpen {
            lastRefreshDate = Date()
            scrapeAndDistribute()
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
                NSLog("[ClaudeMeter] unifiedRefresh JS error: \(error.localizedDescription)")
            } else {
                NSLog("[ClaudeMeter] unifiedRefresh click result: \(result ?? "nil")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.lastRefreshDate = Date()
                    self?.scrapeAndDistribute()
                }
            }
        }
    }

    /// Extract the "Current session" percentage from the shared data store.
    func sessionPercentage(from sections: [UsageSection]) -> Int? {
        for section in sections {
            for meter in section.meters {
                if meter.label.lowercased().contains("current session") {
                    return meter.percentage
                }
            }
        }
        return nil
    }

    /// v2.7.1's exact login-page test, used for the primary account.
    private func isLoginURL(_ url: String) -> Bool {
        url.contains("/login") || url.contains("/signin") || url.contains("accounts.google.com")
    }

    /// Wider hint for secondary accounts: a login page, or any page outside
    /// claude.ai (an SSO identity provider such as Okta or Microsoft Entra
    /// ID). Only a hint: confirmSignedOut asks the API before acting.
    private func looksSignedOut(_ url: String) -> Bool {
        if isLoginURL(url) { return true }
        guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return false }
        return host != "claude.ai" && !host.hasSuffix(".claude.ai")
    }

    // MARK: - Scrape & Distribute

    /// Coordinator: tries the JSON-primary path first, falls back to DOM scrape
    /// when JSON is disabled, errored, or its in-memory circuit breaker has tripped.
    /// Both paths funnel through the same empty-streak gate and badge/model updates,
    /// so callers see a uniform interface regardless of which path succeeded.
    func scrapeAndDistribute() {
        let forceDOM = UserDefaults.standard.bool(forKey: AppDelegate.forceDOMOnlyKey)
        // Auto-reset a stale circuit so JSON gets periodic re-attempts. The
        // circuit re-opens on its own if 5 fresh failures recur.
        if jsonCircuitOpen, let openedAt = jsonCircuitOpenedAt,
           Date().timeIntervalSince(openedAt) >= Self.jsonCircuitResetInterval {
            NSLog("%@", "[ClaudeMeter] json circuit auto-reset after \(Int(Self.jsonCircuitResetInterval/60))min cooldown")
            jsonCircuitOpen = false
            jsonConsecutiveFailures = 0
            jsonCircuitOpenedAt = nil
        }
        // A pinned org is metered through the JSON path only: the DOM page
        // could be showing a different org, so it never stands in.
        let pinned = record.orgPinned
        if !pinned && (forceDOM || jsonCircuitOpen) {
            let reason = forceDOM ? "forceDOMOnly=true" : "json circuit open"
            logFetchOutcome(path: "dom", outcome: "selected", detail: reason)
            scrapeViaDOM()
            return
        }

        fetchViaJSON { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let sections):
                if sections.isEmpty && pinned {
                    self.logFetchOutcome(path: "json", outcome: "empty", detail: "n=0 pinned org, no DOM fallback")
                    self.distributeFetchResult([], path: "json")
                } else if sections.isEmpty {
                    // Empty means our permissive Codable couldn't pull any meters
                    // from the response (shape mismatch or auth-soft-fail).
                    // Treat as failure and fall through to DOM rather than
                    // letting the empty-streak gate eventually clear the UI.
                    self.jsonConsecutiveFailures += 1
                    self.logFetchOutcome(path: "json", outcome: "empty", detail: "n=0 failures=\(self.jsonConsecutiveFailures), falling through to DOM")
                    if self.jsonConsecutiveFailures >= Self.jsonFailureCircuitBreaker && !self.jsonCircuitOpen {
                        self.jsonCircuitOpen = true
                        self.jsonCircuitOpenedAt = Date()
                        NSLog("%@", "[ClaudeMeter] json circuit breaker tripped after \(self.jsonConsecutiveFailures) consecutive empty/error responses, falling back to DOM-only (will retry in \(Int(Self.jsonCircuitResetInterval/60))min)")
                    }
                    self.scrapeViaDOM()
                } else {
                    self.jsonConsecutiveFailures = 0
                    self.logFetchOutcome(path: "json", outcome: "success", detail: "n=\(sections.count)")
                    self.distributeFetchResult(sections, path: "json")
                }
            case .failure(let err):
                if pinned {
                    // No DOM fallback and no circuit-breaker count for a pinned
                    // org. Auth errors are confirmed in fetchViaJSON; other
                    // errors keep the last data via the empty-streak gate.
                    if case .http(let status) = err, [401, 403, 404].contains(status) {
                        self.logFetchOutcome(path: "json", outcome: "error", detail: "\(err) pinned org, checking sign-in")
                    } else {
                        self.logFetchOutcome(path: "json", outcome: "error", detail: "\(err) pinned org, no DOM fallback")
                        self.distributeFetchResult([], path: "json")
                    }
                    return
                }
                self.jsonConsecutiveFailures += 1
                self.logFetchOutcome(path: "json", outcome: "error", detail: "\(err) failures=\(self.jsonConsecutiveFailures)")
                if self.jsonConsecutiveFailures >= Self.jsonFailureCircuitBreaker && !self.jsonCircuitOpen {
                    self.jsonCircuitOpen = true
                    self.jsonCircuitOpenedAt = Date()
                    NSLog("%@", "[ClaudeMeter] json circuit breaker tripped after \(self.jsonConsecutiveFailures) consecutive failures, falling back to DOM-only (will retry in \(Int(Self.jsonCircuitResetInterval/60))min)")
                }
                self.scrapeViaDOM()
            }
        }
    }

    /// DOM scrape path: runs the JS scraper in WKWebView and funnels results
    /// through the shared distribution gate. Kept as a working fallback because
    /// the JSON endpoint is undocumented and may rotate.
    private func scrapeViaDOM() {
        webView.evaluateJavaScript(AppDelegate.scrapeUsageJS) { [weak self] result, error in
            guard let self = self else { return }

            // A nil/non-string result or an empty string means the JS errored
            // before producing JSON. Treat as an empty scrape: counts toward
            // the failure streak so a persistent JS error eventually surfaces
            // the "—%" placeholder rather than indefinitely keeping stale data.
            let sections: [UsageSection]
            if let jsonStr = result as? String, !jsonStr.isEmpty {
                sections = Self.parseUsageJSON(jsonStr)
            } else {
                if let error = error {
                    self.logFetchOutcome(path: "dom", outcome: "error", detail: "JS error: \(error.localizedDescription)")
                } else {
                    self.logFetchOutcome(path: "dom", outcome: "empty", detail: "no data scraped")
                }
                sections = []
            }

            if !sections.isEmpty {
                self.logFetchOutcome(path: "dom", outcome: "success", detail: "n=\(sections.count)")
            }
            self.distributeFetchResult(sections, path: "dom")
        }
    }

    /// Shared distribution + empty-streak gate. Both JSON and DOM paths feed
    /// here so the popover and badge see a single source of truth.
    func distributeFetchResult(_ sections: [UsageSection], path: String) {
        guard !isTornDown else { return }
        if sections.isEmpty {
            // Transient empty — keep last-known data on screen. Only a
            // sustained streak (threshold) is treated as a real failure.
            self.consecutiveEmptyScrapes += 1
            NSLog("[ClaudeMeter] scraped 0 sections via \(path) (streak: \(self.consecutiveEmptyScrapes)/\(Self.emptyScrapeFailureThreshold))")
            if self.consecutiveEmptyScrapes >= Self.emptyScrapeFailureThreshold {
                NSLog("[ClaudeMeter] empty-scrape threshold reached, surfacing failure")
                self.latestSections = []
                self.usageView?.update(sections: [])
                // Each badge side resets on its own account's failure streak.
                if self.app.showMenuBarBadge && self.app.popover?.isShown != true {
                    self.app.badgeAccountFailed(self, reason: "empty-scrape streak \(self.consecutiveEmptyScrapes)")
                }
            }
            return
        }

        self.consecutiveEmptyScrapes = 0
        self.setSignedOut(false, reason: "fetch succeeded")
        UserDefaults.standard.set(path, forKey: self.lastFetchPathKey)
        NSLog("[ClaudeMeter] distributed \(sections.count) sections via \(path)")
        let sections = self.applyResetEstimates(to: sections)
        self.latestSections = sections
        // Name the account in notification titles only once a second account
        // exists, so single-account titles stay exactly as before.
        self.notifier.evaluate(sections: sections, accountID: self.id,
                               accountLabel: self.app.accounts.count >= 2 ? self.record.displayName : nil)

        let sessionPct = self.sessionPercentage(from: sections) ?? 0
        let weeklyPct = self.weeklyPercentage(from: sections) ?? 0
        self.history.append(timestamp: Date(), sessionPct: sessionPct, weeklyPct: weeklyPct)
        self.history.persistThrottled()

        let now = Date()
        let sessionReset = self.sessionResetDate(from: sections, now: now)
        let weeklyReset = self.weeklyResetDate(from: sections, now: now)

        let sessionForecast = UsageForecast.compute(
            samples: self.history.samples,
            currentPct: sessionPct,
            resetAt: sessionReset,
            windowSeconds: 30 * 60,
            minSpanSeconds: 5 * 60,
            keyPath: \UsageHistory.Sample.s,
            now: now
        )
        let weeklyForecast = UsageForecast.compute(
            samples: self.history.samples,
            currentPct: weeklyPct,
            resetAt: weeklyReset,
            windowSeconds: 24 * 3600,
            minSpanSeconds: 30 * 60,
            keyPath: \UsageHistory.Sample.w,
            now: now
        )

        self.lastSessionForecast = sessionForecast
        self.lastWeeklyForecast = weeklyForecast
        self.lastSessionResetAt = sessionReset
        self.lastWeeklyResetAt = weeklyReset
        self.usageView?.update(
            sections: sections,
            sessionForecast: sessionForecast,
            weeklyForecast: weeklyForecast,
            sessionResetAt: sessionReset,
            weeklyResetAt: weeklyReset,
            history: self.history
        )
        self.usageView?.setStatusFresh(true)
        self.app.updateBadgeFromModel()
        self.app.updateMenuBarTooltip()
    }

    /// Extract the headline weekly percentage (the unscoped "Weekly" / "Weekly usage"
    /// meter, falling back to the first weekly meter in the section).
    func weeklyPercentage(from sections: [UsageSection]) -> Int? {
        for section in sections where section.title.lowercased().contains("weekly") {
            for meter in section.meters {
                let l = meter.label.lowercased()
                if l == "weekly" || l == "weekly usage" || l.hasPrefix("weekly usage") {
                    return meter.percentage
                }
            }
            if let first = section.meters.first { return first.percentage }
        }
        return nil
    }

    /// Find the session-meter detail string and parse a reset date out of it.
    /// Falls back to now + 5h if the detail is missing or unparseable.
    func sessionResetDate(from sections: [UsageSection], now: Date) -> Date {
        for section in sections {
            for meter in section.meters where meter.label.lowercased().contains("current session") {
                if let parsed = Date.parseClaudeReset(meter.detail, now: now) { return parsed }
            }
        }
        return now.addingTimeInterval(5 * 3600)
    }

    /// Weekly reset: parse from any weekly meter's detail; fall back to next Monday 00:00 local.
    func weeklyResetDate(from sections: [UsageSection], now: Date) -> Date {
        for section in sections where section.title.lowercased().contains("weekly") {
            for meter in section.meters {
                if let parsed = Date.parseClaudeReset(meter.detail, now: now) { return parsed }
            }
        }
        var comps = DateComponents()
        comps.weekday = 2 // Monday
        comps.hour = 0
        comps.minute = 0
        return Calendar.current.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(7 * 24 * 3600)
    }

    /// Centralized telemetry sink for fetch outcomes. Mirrors setBadgeTitle's
    /// NSLog("%@", ...) convention so the QA pipeline can detect path/outcome
    /// transitions from stderr alone.
    func logFetchOutcome(path: String, outcome: String, detail: String) {
        NSLog("%@", "[ClaudeMeter] fetch path=\(path) outcome=\(outcome) \(detail)")
    }

    // MARK: - Reset Estimation (DOM fallback)

    // Key families; the account ID follows the family, the meter label is last.
    static let firstSeenFamily = "resetEstimate.firstSeen"
    static let firstSeenPctFamily = "resetEstimate.firstSeenPct"

    /// Fills missing UsageMeter.resetAt values with estimates. JSON path already
    /// populates resetAt directly; DOM path either parses from meter.detail or
    /// falls back to a "first seen" anchor in UserDefaults plus a fixed window
    /// (5h session, 7d weekly). The anchor is reset whenever the percentage
    /// drops, since that signals a new cycle.
    func applyResetEstimates(to sections: [UsageSection]) -> [UsageSection] {
        let now = Date()
        let defaults = UserDefaults.standard
        return sections.map { section in
            let meters = section.meters.map { meter -> UsageMeter in
                if meter.resetAt != nil { return meter }

                // First, try parsing the detail string (DOM path supplies things
                // like "Resets at 3:42pm").
                if !meter.detail.isEmpty,
                   let parsed = Date.parseClaudeReset(meter.detail, now: now) {
                    var copy = meter
                    copy.resetAt = parsed
                    return copy
                }

                // Fall back to a persisted first-seen anchor only for meters
                // whose reset cadence we actually know (5h session, 7d weekly).
                // Other meters (Extra usage = monthly billing reset, All models
                // / Sonnet only = arbitrary tier-specific cadences) stay nil
                // rather than getting a misleading short countdown.
                let key = meter.label.lowercased()
                let isSession = key.contains("current session")
                let isWeekly = section.title.lowercased().contains("weekly") || key.contains("weekly")
                guard isSession || isWeekly else { return meter }

                let firstSeenKey = AccountKeys.key(Self.firstSeenFamily, self.id, key)
                let firstSeenPctKey = AccountKeys.key(Self.firstSeenPctFamily, self.id, key)
                let stored = defaults.double(forKey: firstSeenKey)
                let storedPct = defaults.integer(forKey: firstSeenPctKey)
                let windowSeconds: TimeInterval = isWeekly ? 7 * 24 * 3600 : 5 * 3600

                let anchor: TimeInterval
                if stored <= 0 || meter.percentage < storedPct {
                    anchor = now.timeIntervalSince1970
                    defaults.set(anchor, forKey: firstSeenKey)
                    defaults.set(meter.percentage, forKey: firstSeenPctKey)
                } else {
                    anchor = stored
                }

                var copy = meter
                copy.resetAt = Date(timeIntervalSince1970: anchor + windowSeconds)
                return copy
            }
            return UsageSection(title: section.title, meters: meters)
        }
    }

    // MARK: - JSON Fetch Path

    /// JSON-primary fetch. Copies cookies from the WKWebView data store into a
    /// per-call URLSession, discovers the org UUID lazily, and decodes the
    /// undocumented /api/organizations/{uuid}/usage response.
    func fetchViaJSON(completion: @escaping (Result<[UsageSection], FetchError>) -> Void) {
        if jsonFetchInFlight {
            completion(.failure(.transport(NSError(domain: "ClaudeMeter", code: -1, userInfo: [NSLocalizedDescriptionKey: "fetch already in flight"]))))
            return
        }
        jsonFetchInFlight = true

        copyCookiesToSession { [weak self] session in
            guard let self = self else { return }
            self.discoverOrgUUID(session: session) { [weak self] uuid in
                guard let self = self else { return }
                guard let uuid = uuid else {
                    session.finishTasksAndInvalidate()
                    self.jsonFetchInFlight = false
                    completion(.failure(.noOrg))
                    return
                }

                let urlStr = "https://claude.ai" + String(format: AppDelegate.apiUsagePath, uuid)
                guard let url = URL(string: urlStr) else {
                    session.finishTasksAndInvalidate()
                    self.jsonFetchInFlight = false
                    completion(.failure(.noOrg))
                    return
                }

                var req = URLRequest(url: url)
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                req.setValue(AppDelegate.safariUA, forHTTPHeaderField: "User-Agent")

                session.dataTask(with: req) { [weak self] data, response, error in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        self.jsonFetchInFlight = false
                        if let error = error {
                            completion(.failure(.transport(error)))
                            return
                        }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 401 || status == 403 || status == 404 {
                            if self.record.orgPinned {
                                // Never silently swap a user-pinned org for another
                                // one: keep the UUID; sign out only if the API agrees.
                                self.confirmSignedOut(reason: "usage API HTTP \(status) for pinned org")
                            } else {
                                // Cached UUID may be stale; clear so next attempt rediscovers.
                                self.cachedOrgUUID = nil
                                self.persistRecord()
                            }
                            completion(.failure(.http(status)))
                            return
                        }
                        if status < 200 || status >= 300 {
                            completion(.failure(.http(status)))
                            return
                        }
                        guard let data = data else {
                            completion(.failure(.http(status)))
                            return
                        }
                        do {
                            let decoded = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
                            let sections = self.normalizeJSONResponse(decoded)
                            completion(.success(sections))
                        } catch {
                            completion(.failure(.decode(error)))
                        }
                    }
                }.resume()
                // Last task on this per-call session: let it finish, then free it.
                session.finishTasksAndInvalidate()
            }
        }
    }

    /// Lazily discovers the org UUID. Returns the cached value when present.
    /// Picks the org whose capabilities include claude_pro/claude_max when present,
    /// else the first org in the list.
    func discoverOrgUUID(session: URLSession, completion: @escaping (String?) -> Void) {
        // A user-pinned org (chosen at sign-in) is never re-picked.
        if record.orgPinned {
            completion(cachedOrgUUID)
            return
        }
        // Re-fetch when uuid is cached but plan tier isn't, so the chip
        // populates after upgrading to a build that captures it.
        if let cached = cachedOrgUUID, !cached.isEmpty, cachedPlanTier != nil {
            completion(cached)
            return
        }
        requestOrgList(session: session, context: "discoverOrgUUID") { [weak self] _, list in
            guard let self = self else { return }
            let orgs = list ?? []
            let preferred = orgs.first { ($0.capabilities ?? []).contains { c in
                c == "claude_pro" || c == "claude_max"
            } }
            let chosen = preferred ?? orgs.first
            if let chosen = chosen {
                self.cachedOrgUUID = chosen.uuid
                if let name = chosen.name, !name.isEmpty {
                    self.record.orgName = name
                }
                if let tier = chosen.rate_limit_tier, !tier.isEmpty {
                    self.cachedPlanTier = tier
                    NSLog("%@", "[ClaudeMeter] plan tier resolved: \(tier)")
                }
                self.persistRecord()
                self.usageView?.planTierDisplayName = AppDelegate.planTierDisplayName(slug: self.cachedPlanTier)
            }
            completion(chosen?.uuid)
        }
    }

    /// GET /api/organizations with this account's cookies. Calls back on the
    /// main queue with the HTTP status (0 on a transport error) and the
    /// decoded orgs (nil unless 2xx). Logs counts only.
    func requestOrgList(session: URLSession, context: String, quiet: Bool = false,
                        completion: @escaping (Int, [OrgListResponse.Org]?) -> Void) {
        var req = URLRequest(url: AppDelegate.apiOrgsURL)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(AppDelegate.safariUA, forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { data, response, err in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let err = err {
                    if !quiet { NSLog("%@", "[ClaudeMeter] \(context) transport error: \(err.localizedDescription)") }
                    completion(0, nil); return
                }
                guard status >= 200, status < 300, let data = data else {
                    if !quiet { NSLog("%@", "[ClaudeMeter] \(context) HTTP \(status), bytes=\(data?.count ?? 0)") }
                    completion(status, nil); return
                }
                var orgs: [OrgListResponse.Org] = []
                if let arr = try? JSONDecoder().decode([OrgListResponse.Org].self, from: data) {
                    orgs = arr
                } else if let env = try? JSONDecoder().decode(OrgListResponse.self, from: data) {
                    orgs = env.organizations ?? []
                } else {
                    NSLog("%@", "[ClaudeMeter] \(context) decode failed (\(data.count) bytes)")
                }
                if !quiet { NSLog("%@", "[ClaudeMeter] \(context) got \(orgs.count) orgs") }
                completion(status, orgs)
            }
        }.resume()
    }

    /// Proactive plan-tier fetch independent of the usage JSON path. The usage
    /// endpoint may be circuit-broken or shape-mismatched, but plan tier still
    /// works because /api/organizations is a different endpoint.
    func refreshPlanTierIfNeeded() {
        copyCookiesToSession { [weak self] session in
            guard let self = self else { session.finishTasksAndInvalidate(); return }
            self.discoverOrgUUID(session: session) { _ in session.finishTasksAndInvalidate() }
        }
    }

    /// Snapshots all WKWebView cookies into a URLSession so the JSON request
    /// rides the same authenticated session as the page itself.
    /// The caller owns the returned per-call session and must call
    /// finishTasksAndInvalidate() after creating its last task.
    func copyCookiesToSession(logCount: Bool = true, completion: @escaping (URLSession) -> Void) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { cookies in
            // ephemeral config already has its own in-memory HTTPCookieStorage.
            // The previous sharedCookieStorage(forGroupContainerIdentifier:)
            // path required an app-group entitlement we don't have, which is
            // why cookies weren't actually being attached to outbound requests.
            let config = URLSessionConfiguration.ephemeral
            if let jar = config.httpCookieStorage {
                for c in cookies { jar.setCookie(c) }
            }
            config.httpShouldSetCookies = true
            config.httpCookieAcceptPolicy = .always
            if logCount {
                NSLog("%@", "[ClaudeMeter] copyCookiesToSession: attached \(cookies.count) cookies")
            }
            let session = URLSession(configuration: config)
            DispatchQueue.main.async { completion(session) }
        }
    }

    /// Maps the JSON API response into the existing UsageSection/UsageMeter
    /// shape, preserving the label conventions ("Current session", "Weekly",
    /// "Opus", etc.) so sessionPercentage(from:) and updateBadgeFromModel
    /// keep working unchanged.
    func normalizeJSONResponse(_ response: UsageAPIResponse) -> [UsageSection] {
        func percent(_ w: UsageAPIResponse.Window) -> Int {
            if let p = w.percent_used { return p }
            // Current schema returns `utilization` as a percentage (0-100), e.g.
            // `seven_day: 22.0` for 22%, `seven_day_sonnet: 1.0` for 1%. The
            // pre-v2.6 heuristic ("if u <= 1.0 treat as fraction and ×100") was
            // a guess for the old undocumented shape and is now wrong: a real
            // 1% value got scaled to 100%. Trust the percentage scale directly.
            if let u = w.utilization {
                return Int(u.rounded())
            }
            return 0
        }
        func detail(_ w: UsageAPIResponse.Window) -> String {
            if let r = w.resets_at, !r.isEmpty { return "Resets \(r)" }
            return ""
        }
        func resetDate(_ w: UsageAPIResponse.Window) -> Date? {
            guard let r = w.resets_at, !r.isEmpty else { return nil }
            // Try ISO-8601 first (the JSON path's canonical form), then fall
            // back to the v2.1 string parser for human-format strings.
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: r) { return d }
            let isoNoFrac = ISO8601DateFormatter()
            isoNoFrac.formatOptions = [.withInternetDateTime]
            if let d = isoNoFrac.date(from: r) { return d }
            return Date.parseClaudeReset(r)
        }

        var sessionMeters: [UsageMeter] = []
        var weeklyMeters: [UsageMeter] = []

        // Session window: prefer current `five_hour`, fall back to legacy `session`.
        if let s = response.five_hour ?? response.session {
            let label = s.label ?? "Current session"
            sessionMeters.append(UsageMeter(label: label, percentage: percent(s), detail: detail(s), resetAt: resetDate(s)))
        }
        // Weekly aggregate: prefer current `seven_day`, fall back to legacy `weekly`.
        if let w = response.seven_day ?? response.weekly {
            let label = w.label ?? "Weekly usage"
            weeklyMeters.append(UsageMeter(label: label, percentage: percent(w), detail: detail(w), resetAt: resetDate(w)))
        }
        // Per-model weekly windows. Anthropic's current shape splits these into
        // named keys (`seven_day_opus`, etc.); the older `per_model` array is
        // honored too for resilience.
        let perModelWindows: [(model: String, window: UsageAPIResponse.Window?)] = [
            ("Opus",   response.seven_day_opus),
            ("Sonnet", response.seven_day_sonnet),
        ]
        for (modelName, window) in perModelWindows {
            guard let w = window else { continue }
            weeklyMeters.append(UsageMeter(label: "Weekly \(modelName) usage",
                                            percentage: percent(w), detail: detail(w), resetAt: resetDate(w)))
        }
        if let perModel = response.per_model {
            for w in perModel {
                let model = w.model ?? ""
                let baseLabel = w.label ?? (model.isEmpty ? "Weekly" : "Weekly \(model) usage")
                weeklyMeters.append(UsageMeter(label: baseLabel, percentage: percent(w), detail: detail(w), resetAt: resetDate(w)))
            }
        }

        var out: [UsageSection] = []
        if !sessionMeters.isEmpty {
            out.append(UsageSection(title: "Session limit", meters: sessionMeters))
        }
        if !weeklyMeters.isEmpty {
            out.append(UsageSection(title: "Weekly limit", meters: weeklyMeters))
        }
        return out
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

// MARK: - Accounts (model, key namespacing, persistence, migration)

/// Where an account appears in the two-slot menu-bar badge.
enum BadgeSlot: String, Codable {
    case left, right, hidden
}

/// Persisted, non-secret description of one metered claude.ai account.
/// Cookies and tokens never live here: WebKit's website data store (the
/// default store for the primary account, an identifier-keyed store for any
/// other) is the only session persistence.
struct AccountRecord: Codable, Equatable {
    /// Fixed ID of the first account, the one Claude Desktop's cookie import
    /// feeds and that lives in WKWebsiteDataStore.default().
    static let primaryID = "primary"

    let id: String
    var displayName: String
    /// 1 to 3 characters shown in the badge once two or more accounts exist.
    var badgeLabel: String
    var badgeSlot: BadgeSlot
    var email: String?
    var orgUUID: String?
    var orgName: String?
    var planTier: String?
    /// True once the user picked this org. A pinned org is never silently
    /// replaced: an auth failure keeps the UUID and the account reads as
    /// signed out instead.
    var orgPinned: Bool
    /// Identifier for WKWebsiteDataStore(forIdentifier:); nil means the
    /// default store (primary account only).
    var storeIdentifier: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, displayName, badgeLabel, badgeSlot, email, orgUUID, orgName, planTier, orgPinned, storeIdentifier
    }

    var isPrimary: Bool { id == Self.primaryID }

    /// Account IDs are "primary" or a UUID string. Neither contains a dot, so
    /// the ID is always exactly one segment of a namespaced key.
    static func isValidID(_ id: String) -> Bool {
        id == primaryID || UUID(uuidString: id) != nil
    }

    static func defaultBadgeLabel(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    static func makePrimary(orgUUID: String? = nil, planTier: String? = nil) -> AccountRecord {
        let name = "Personal"
        return AccountRecord(id: primaryID, displayName: name,
                             badgeLabel: defaultBadgeLabel(for: name), badgeSlot: .left,
                             email: nil, orgUUID: orgUUID, orgName: nil, planTier: planTier,
                             orgPinned: false, storeIdentifier: nil)
    }
}

extension AccountRecord {
    /// Tolerant decoding. Only `id` is required (and must be valid); every
    /// other field falls back to a default, and an unknown badgeSlot reads as
    /// hidden, so a record written by an older or newer build never fails the
    /// list. Declared in an extension to keep the memberwise initializer.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        guard AccountRecord.isValidID(id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "invalid account id")
        }
        let isPrimary = id == AccountRecord.primaryID
        func string(_ key: CodingKeys) -> String? {
            guard let value = try? c.decodeIfPresent(String.self, forKey: key), !value.isEmpty else { return nil }
            return value
        }
        let name = string(.displayName) ?? (isPrimary ? "Personal" : "Account")
        let slot: BadgeSlot
        if let raw = string(.badgeSlot) {
            slot = BadgeSlot(rawValue: raw) ?? .hidden
        } else {
            slot = isPrimary ? .left : .hidden
        }
        self.init(id: id,
                  displayName: name,
                  badgeLabel: string(.badgeLabel) ?? AccountRecord.defaultBadgeLabel(for: name),
                  badgeSlot: slot,
                  email: string(.email),
                  orgUUID: string(.orgUUID),
                  orgName: string(.orgName),
                  planTier: string(.planTier),
                  orgPinned: (try? c.decodeIfPresent(Bool.self, forKey: .orgPinned)) ?? false,
                  storeIdentifier: string(.storeIdentifier))
    }
}

/// Builds per-account UserDefaults keys. The account ID sits right after the
/// key family and before any trailing component:
///   lastFetchPath.<id>
///   resetEstimate.firstSeen.<id>.<meter label>
///   notif.fired.<id>.<scope>.<threshold>.<cycle>
/// so ThresholdNotifier.pruneStaleKeys still reads the cycle timestamp as the
/// last dot-separated component.
enum AccountKeys {
    static func key(_ family: String, _ accountID: String, _ rest: String? = nil) -> String {
        guard let rest = rest, !rest.isEmpty else { return "\(family).\(accountID)" }
        return "\(family).\(accountID).\(rest)"
    }
}

/// Loads and saves the account list and runs the one-time migration of
/// v2.7.1's global per-account state. The list is a JSON string in
/// UserDefaults: {"schema": 1, "accounts": [ ...records... ]}.
enum AccountStore {
    static let listKey = "accounts.list"
    static let unreadableKey = "accounts.list.unreadable"
    static let listSchemaVersion = 1
    static let migrationVersionKey = "accounts.migrationVersion"
    static let currentMigrationVersion = 1

    /// What is stored, as read. Raw dictionaries are kept so a save
    /// round-trips fields this build does not know, plus any record it could
    /// not decode, instead of dropping them.
    private struct Stored {
        var records: [AccountRecord] = []
        var rawByID: [String: [String: Any]] = [:]
        var undecodable: [Any] = []
        var schema = AccountStore.listSchemaVersion
        /// False when a value exists but is not a readable list. Saving is
        /// then refused, so a list we failed to read is never overwritten.
        var writable = true
    }

    private static func read() -> Stored {
        var out = Stored()
        guard let json = UserDefaults.standard.string(forKey: listKey) else { return out }
        let parsed = json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let elements: [Any]?
        if let envelope = parsed as? [String: Any] {
            elements = envelope["accounts"] as? [Any]
            out.schema = max(listSchemaVersion, envelope["schema"] as? Int ?? listSchemaVersion)
        } else {
            elements = parsed as? [Any]   // bare array, written before the schema envelope
        }
        guard let items = elements else {
            preserveUnreadable(json, reason: "not a readable account list")
            out.writable = false
            return out
        }
        for item in items {
            guard let dict = item as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let record = try? JSONDecoder().decode(AccountRecord.self, from: data),
                  out.rawByID[record.id] == nil else {
                out.undecodable.append(item)
                continue
            }
            out.records.append(record)
            out.rawByID[record.id] = dict
        }
        if !out.undecodable.isEmpty {
            preserveUnreadable(json, reason: "\(out.undecodable.count) record(s) could not be decoded and are kept as-is")
        }
        return out
    }

    /// Keeps the first unreadable value seen (non-secret) under unreadableKey.
    private static func preserveUnreadable(_ json: String, reason: String) {
        guard UserDefaults.standard.object(forKey: unreadableKey) == nil else { return }
        UserDefaults.standard.set(json, forKey: unreadableKey)
        NSLog("%@", "[ClaudeMeter] accounts: \(reason); raw value kept in \(unreadableKey)")
    }

    static func load() -> [AccountRecord] {
        read().records
    }

    /// True when the saved list (if any) parsed and every record decoded.
    static var isListFullyReadable: Bool {
        let stored = read()
        return stored.writable && stored.undecodable.isEmpty
    }

    static func save(_ records: [AccountRecord]) {
        let stored = read()
        guard stored.writable else {
            NSLog("%@", "[ClaudeMeter] accounts: not saving, the stored list is unreadable (see \(unreadableKey))")
            return
        }
        let knownKeys = Set(AccountRecord.CodingKeys.allCases.map { $0.rawValue })
        var items: [Any] = []
        for record in records {
            guard let data = try? JSONEncoder().encode(record),
                  let known = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            // Start from what was stored so unknown (newer) fields survive,
            // then apply every field this build knows, dropping known fields
            // that are now nil.
            var merged = stored.rawByID[record.id] ?? [:]
            for key in knownKeys { merged.removeValue(forKey: key) }
            for (key, value) in known { merged[key] = value }
            items.append(merged)
        }
        items.append(contentsOf: stored.undecodable)
        let envelope: [String: Any] = ["schema": stored.schema, "accounts": items]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: listKey)
    }

    /// Inserts or replaces one record by ID, keeping every other record.
    static func upsert(_ record: AccountRecord) {
        var records = load()
        if let i = records.firstIndex(where: { $0.id == record.id }) {
            records[i] = record
        } else {
            records.insert(record, at: record.isPrimary ? 0 : records.count)
        }
        save(records)
    }

    /// Deletes one record from the saved list (other records untouched).
    static func remove(id: String) {
        save(load().filter { $0.id != id })
    }

    /// Every per-account key family. Keys are "<family>.<id>" or
    /// "<family>.<id>.<rest>".
    static var perAccountKeyFamilies: [String] {
        [AppDelegate.lastFetchPathKey, AppDelegate.lastBadgePercentageKey,
         AccountController.firstSeenFamily, AccountController.firstSeenPctFamily,
         ThresholdNotifier.cycleStartFamily, ThresholdNotifier.firedFamily,
         ThresholdNotifier.lastPctFamily, ThresholdNotifier.snoozedFamily]
    }

    /// Removes every namespaced key of one secondary account, matching the ID
    /// as an exact key segment (never a bare prefix). Returns the count.
    @discardableResult
    static func removeKeys(forAccount id: String) -> Int {
        guard AccountRecord.isValidID(id), id != AccountRecord.primaryID else { return 0 }
        let defaults = UserDefaults.standard
        var removed = 0
        for key in defaults.dictionaryRepresentation().keys {
            for family in perAccountKeyFamilies where key == "\(family).\(id)" || key.hasPrefix("\(family).\(id).") {
                defaults.removeObject(forKey: key)
                removed += 1
                break
            }
        }
        return removed
    }

    /// The primary account's record, created and saved if missing.
    static func primaryRecord() -> AccountRecord {
        if let existing = load().first(where: { $0.isPrimary }) { return existing }
        let record = AccountRecord.makePrimary()
        upsert(record)
        return record
    }

    /// One-time upgrade from v2.7.1. Copies the global per-account values and
    /// history.json into the primary account's namespace, then records the
    /// migration version. Copy-only: every legacy key and history.json stay in
    /// place for one release as a rollback path, and a destination that
    /// already exists is never overwritten, so re-running is harmless. If the
    /// history copy fails the version is not recorded, so the next launch
    /// retries (UsageHistory also reads history.json for the primary account
    /// until history-primary.json exists).
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: migrationVersionKey) < currentMigrationVersion else { return }
        let pid = AccountRecord.primaryID
        var copied = 0

        func copy(_ from: String, to: String) {
            guard let value = defaults.object(forKey: from), defaults.object(forKey: to) == nil else { return }
            defaults.set(value, forKey: to)
            copied += 1
        }

        // Fixed keys.
        copy(AppDelegate.lastFetchPathKey, to: AccountKeys.key(AppDelegate.lastFetchPathKey, pid))
        copy(AppDelegate.lastBadgePercentageKey, to: AccountKeys.key(AppDelegate.lastBadgePercentageKey, pid))
        for scope in ["session", "weekly"] {
            copy("\(ThresholdNotifier.cycleStartFamily).\(scope)",
                 to: AccountKeys.key(ThresholdNotifier.cycleStartFamily, pid, scope))
        }

        // Families with a trailing component. Notification keys qualify only
        // when the component after the family is a scope, which excludes keys
        // that are already namespaced. A reset-estimate key is skipped when its
        // next segment is an account ID ("primary" or a UUID), so no account's
        // keys are ever nested under primary.
        let legacyKeys = Array(defaults.dictionaryRepresentation().keys)
        let notifFamilies = [ThresholdNotifier.firedFamily, ThresholdNotifier.lastPctFamily,
                             ThresholdNotifier.snoozedFamily]
        let resetFamilies = [AccountController.firstSeenFamily, AccountController.firstSeenPctFamily]
        for key in legacyKeys {
            for family in notifFamilies where key.hasPrefix(family + ".") {
                let rest = String(key.dropFirst(family.count + 1))
                if rest.hasPrefix("session.") || rest.hasPrefix("weekly.") {
                    copy(key, to: AccountKeys.key(family, pid, rest))
                }
            }
            for family in resetFamilies where key.hasPrefix(family + ".") {
                let rest = String(key.dropFirst(family.count + 1))
                let segments = rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                let namespaced = segments.count == 2 && AccountRecord.isValidID(String(segments[0]))
                if !rest.isEmpty && !namespaced {
                    copy(key, to: AccountKeys.key(family, pid, rest))
                }
            }
        }

        // Account record: org and tier from the v2.7.1 globals.
        var record = load().first(where: { $0.isPrimary }) ?? AccountRecord.makePrimary()
        if record.orgUUID == nil { record.orgUUID = defaults.string(forKey: AppDelegate.cachedOrgUUIDKey) }
        if record.planTier == nil { record.planTier = defaults.string(forKey: AppDelegate.cachedPlanTierKey) }
        upsert(record)

        // History file.
        var historyOK = true
        let historyResult: String
        let fm = FileManager.default
        let legacy = UsageHistory.legacyFileURL
        let target = UsageHistory.fileURL(accountID: pid)
        if fm.fileExists(atPath: target.path) {
            historyResult = "kept existing"
        } else if fm.fileExists(atPath: legacy.path) {
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: legacy, to: target)
                historyResult = "copied"
            } catch {
                historyOK = false
                historyResult = "copy failed (\(error.localizedDescription)); will retry next launch"
            }
        } else {
            historyResult = "none to copy"
        }

        if historyOK {
            defaults.set(currentMigrationVersion, forKey: migrationVersionKey)
        }
        NSLog("%@", "[ClaudeMeter] accounts migration v\(currentMigrationVersion): copied \(copied) keys into '\(pid)', history: \(historyResult)")
    }
}

// MARK: - Usage Data Model

struct UsageMeter: Equatable {
    let label: String
    let percentage: Int
    let detail: String
    var resetAt: Date?

    init(label: String, percentage: Int, detail: String, resetAt: Date? = nil) {
        self.label = label
        self.percentage = percentage
        self.detail = detail
        self.resetAt = resetAt
    }

    // Equality intentionally ignores resetAt: parseClaudeReset is computed
    // against `now`, so the drifting timestamp would otherwise force a full
    // popover rebuild on every scrape (causing flicker the v1.7 work fixed).
    // The countdown ticker handles its own tick-by-tick updates.
    static func == (lhs: UsageMeter, rhs: UsageMeter) -> Bool {
        return lhs.label == rhs.label
            && lhs.percentage == rhs.percentage
            && lhs.detail == rhs.detail
    }
}

struct UsageSection: Equatable {
    let title: String
    let meters: [UsageMeter]
}

// MARK: - Usage API Models
// Permissive Optional fields throughout — endpoint is undocumented and may
// rotate. The mapper picks whichever non-nil percent representation is present.

struct UsageAPIResponse: Decodable {
    struct Window: Decodable {
        let label: String?
        let utilization: Double?
        let percent_used: Int?
        let resets_at: String?
        let model: String?
    }
    // Current schema (observed 2026-05-07): per-window fields keyed by name
    // (`five_hour`, `seven_day`, `seven_day_opus`, etc.). Older code paths used
    // `session` / `weekly` / `per_model`; left in as Optional for resilience if
    // Anthropic restores them.
    let session: Window?
    let weekly: Window?
    let per_model: [Window]?
    let five_hour: Window?
    let seven_day: Window?
    let seven_day_opus: Window?
    let seven_day_sonnet: Window?
    let seven_day_cowork: Window?
    let seven_day_omelette: Window?
    let seven_day_oauth_apps: Window?
}

struct OrgListResponse: Decodable {
    struct Org: Decodable {
        let uuid: String
        let name: String?
        let capabilities: [String]?
        let rate_limit_tier: String?
    }
    let organizations: [Org]?
}

enum FetchError: Error {
    case noCookies
    case noOrg
    case http(Int)
    case decode(Error)
    case transport(Error)
}

// MARK: - App Paths

/// Application Support folder for this build. The shipping app
/// (com.local.ClaudeMeter) and unbundled binaries keep the historical
/// "ClaudeMeter" folder, so real-app paths never change. Any other bundle ID
/// (for example the QA bundle, com.local.ClaudeMeter.qa) gets a folder named
/// after its bundle ID, so test runs never read, migrate or overwrite the
/// installed app's history files.
enum AppPaths {
    static let shippingBundleID = "com.local.ClaudeMeter"

    static var supportDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let folder: String
        if let id = Bundle.main.bundleIdentifier, !id.isEmpty, id != shippingBundleID {
            folder = id
        } else {
            folder = "ClaudeMeter"
        }
        return base.appendingPathComponent(folder, isDirectory: true)
    }
}

// MARK: - Usage History (ring buffer + disk persistence)

/// Bounded sample buffer for burn-rate / ETA computation. Capped at 24h on
/// retention so the JSON file stays tiny (a few KB) and EWMA over the recent
/// slice is cheap (n typically < 300). Persisted to Application Support so
/// rate estimates survive relaunches.
struct UsageHistory {
    struct Sample: Codable, Equatable {
        let t: TimeInterval
        let s: Int   // session pct
        let w: Int   // weekly pct
    }

    private(set) var samples: [Sample] = []
    private var lastPersist: Date = .distantPast
    /// Where this history persists; nil means in-memory only.
    private(set) var fileURL: URL?
    private static let retentionSeconds: TimeInterval = 24 * 3600
    private static let persistThrottle: TimeInterval = 30

    /// v2.7.1 single-account file. Read only by the one-time migration and
    /// left in place as a rollback path.
    static var legacyFileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("history.json")
    }

    /// Per-account file, e.g. history-primary.json.
    static func fileURL(accountID: String) -> URL {
        AppPaths.supportDirectory.appendingPathComponent("history-\(accountID).json")
    }

    static func loadFromDisk(accountID: String) -> UsageHistory {
        var h = UsageHistory()
        let fileURL = Self.fileURL(accountID: accountID)
        h.fileURL = fileURL
        // Until the migration has produced history-primary.json, the primary
        // account reads v2.7.1's history.json. Writes always go to fileURL.
        var readURL = fileURL
        if accountID == AccountRecord.primaryID,
           !FileManager.default.fileExists(atPath: fileURL.path),
           FileManager.default.fileExists(atPath: legacyFileURL.path) {
            readURL = legacyFileURL
        }
        guard let data = try? Data(contentsOf: readURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return h
        }
        let cutoff = Date().timeIntervalSince1970 - retentionSeconds
        h.samples = envelope.samples.filter { $0.t >= cutoff }
        return h
    }

    mutating func append(timestamp: Date, sessionPct: Int, weeklyPct: Int) {
        let sample = Sample(t: timestamp.timeIntervalSince1970, s: sessionPct, w: weeklyPct)
        samples.append(sample)
        let cutoff = timestamp.timeIntervalSince1970 - Self.retentionSeconds
        if let firstKeep = samples.firstIndex(where: { $0.t >= cutoff }), firstKeep > 0 {
            samples.removeFirst(firstKeep)
        }
    }

    mutating func persistThrottled(now: Date = Date()) {
        guard let url = fileURL else { return }
        guard now.timeIntervalSince(lastPersist) >= Self.persistThrottle else { return }
        lastPersist = now
        let envelope = Envelope(version: 1, samples: samples)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Samples within the last `seconds`, oldest first.
    func recent(seconds: TimeInterval, now: Date = Date()) -> [Sample] {
        let cutoff = now.timeIntervalSince1970 - seconds
        return samples.filter { $0.t >= cutoff }
    }

    private struct Envelope: Codable {
        let version: Int
        let samples: [Sample]
    }
}

// MARK: - Threshold Notifier

/// Fires macOS user notifications when session/weekly usage crosses 50/75/90%.
/// Idempotent per cycle: each (account, scope, threshold, cycleKey) tuple fires
/// at most once. Per-threshold mute toggles (global, shared by all accounts)
/// and a per-account "Snooze rest of cycle" action let users opt out without
/// disabling notifications globally. One shared instance is the
/// UNUserNotificationCenter delegate; all cycle, fired, last-percentage and
/// snooze state is namespaced by account ID (see AccountKeys).
final class ThresholdNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "notif.enabled"
    static let authRequestedKey = "notif.authRequested"
    // Per-account key families: "<family>.<accountId>.<rest>".
    static let cycleStartFamily = "notif.cycleStart"
    static let firedFamily = "notif.fired"
    static let lastPctFamily = "notif.lastPct"
    static let snoozedFamily = "notif.snoozed"
    static let categoryID = "CM_THRESHOLD"
    static let snoozeActionID = "CM_SNOOZE_CYCLE"

    private let thresholds: [Int] = [50, 75, 90]
    private let center = UNUserNotificationCenter.current()

    enum Scope: String {
        case session
        case weekly
    }

    override init() {
        super.init()
        registerCategory()
        pruneStaleKeys()
    }

    private func registerCategory() {
        let snooze = UNNotificationAction(
            identifier: Self.snoozeActionID,
            title: "Snooze rest of cycle",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [snooze],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// `accountLabel` is non-nil only when two or more accounts exist; it is
    /// then prefixed to notification titles.
    func evaluate(sections: [UsageSection], accountID: String, accountLabel: String?) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }

        let now = Date()
        let sessionPct = percentage(in: sections, scope: .session)
        let weeklyPct = percentage(in: sections, scope: .weekly)
        let sessionDetail = detail(in: sections, scope: .session)
        let weeklyDetail = detail(in: sections, scope: .weekly)

        if let pct = sessionPct {
            evaluateScope(.session, pct: pct, detail: sessionDetail, sections: sections, now: now,
                          accountID: accountID, accountLabel: accountLabel)
        }
        if let pct = weeklyPct {
            evaluateScope(.weekly, pct: pct, detail: weeklyDetail, sections: sections, now: now,
                          accountID: accountID, accountLabel: accountLabel)
        }
    }

    private func evaluateScope(_ scope: Scope, pct: Int, detail: String, sections: [UsageSection], now: Date,
                               accountID: String, accountLabel: String?) {
        let cycleKey = self.cycleKey(for: scope, accountID: accountID, sections: sections, now: now)
        let lastPctKey = AccountKeys.key(Self.lastPctFamily, accountID, "\(scope.rawValue).\(cycleKey)")
        let snoozedKey = AccountKeys.key(Self.snoozedFamily, accountID, "\(scope.rawValue).\(cycleKey)")
        let defaults = UserDefaults.standard
        let lastPct = defaults.integer(forKey: lastPctKey)
        let snoozed = defaults.bool(forKey: snoozedKey)

        if !snoozed {
            for threshold in thresholds {
                let muteKey = "notif.mute.\(scope.rawValue).\(threshold)"
                let firedKey = AccountKeys.key(Self.firedFamily, accountID, "\(scope.rawValue).\(threshold).\(cycleKey)")
                let muted = defaults.bool(forKey: muteKey)
                let alreadyFired = defaults.bool(forKey: firedKey)
                if lastPct < threshold && pct >= threshold && !muted && !alreadyFired {
                    // Set fired BEFORE dispatching so concurrent evaluates can't double-fire.
                    defaults.set(true, forKey: firedKey)
                    fire(scope: scope, threshold: threshold, detail: detail, cycleKey: cycleKey,
                         accountID: accountID, accountLabel: accountLabel)
                }
            }
        }

        defaults.set(pct, forKey: lastPctKey)
    }

    /// Manually fires a synthetic notification so the user can verify their
    /// Focus / Do-Not-Disturb settings actually let ClaudeMeter through.
    /// Bypasses the enabled-gate (the whole point is to debug delivery) but
    /// still rides the lazy-auth path so the OS prompt appears on first use.
    func sendTestNotification() {
        let title = "ClaudeMeter test notification"
        let body = "If you can see this, alerts are wired up correctly."
        let dispatch = { [weak self] in
            self?.dispatchNotification(title: title, body: body, scope: .session, cycleKey: "test",
                                       accountID: AccountRecord.primaryID)
        }
        if UserDefaults.standard.bool(forKey: Self.authRequestedKey) {
            dispatch()
            return
        }
        UserDefaults.standard.set(true, forKey: Self.authRequestedKey)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                DispatchQueue.main.async { dispatch() }
            }
        }
    }

    private func fire(scope: Scope, threshold: Int, detail: String, cycleKey: String,
                      accountID: String, accountLabel: String?) {
        let scopeName = (scope == .session) ? "session" : "weekly"
        let baseTitle = "Claude \(scopeName) at \(threshold)%"
        let title = accountLabel.map { "\($0): \(baseTitle)" } ?? baseTitle
        let body: String
        if !detail.isEmpty {
            body = detail
        } else {
            body = "You've used \(threshold)% of your \(scopeName) limit."
        }

        let dispatch = { [weak self] in
            self?.dispatchNotification(title: title, body: body, scope: scope, cycleKey: cycleKey,
                                       accountID: accountID)
        }

        if UserDefaults.standard.bool(forKey: Self.authRequestedKey) {
            dispatch()
            return
        }

        // Lazy authorization request on first fire (privacy-respecting).
        UserDefaults.standard.set(true, forKey: Self.authRequestedKey)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                DispatchQueue.main.async { dispatch() }
            }
        }
    }

    private func dispatchNotification(title: String, body: String, scope: Scope, cycleKey: String,
                                      accountID: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.categoryID
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["scope": scope.rawValue, "cycleKey": cycleKey, "accountID": accountID]

        let req = UNNotificationRequest(
            identifier: "CM_\(scope.rawValue)_\(cycleKey)_\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(req) { err in
            if let err = err {
                NSLog("[ClaudeMeter] notif dispatch error: %@", err.localizedDescription)
            }
        }
    }

    /// Removes delivered notifications that belong to one account.
    func removeDeliveredNotifications(forAccount accountID: String) {
        center.getDeliveredNotifications { [weak self] delivered in
            let ids = delivered.filter {
                ($0.request.content.userInfo["accountID"] as? String) == accountID
            }.map { $0.request.identifier }
            guard !ids.isEmpty else { return }
            self?.center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: - Cycle key

    /// Stable identifier for the current cycle window. Prefer the parsed reset
    /// timestamp (rounded to seconds); fall back to a rolling anchor stored in
    /// UserDefaults (per account) when the detail string isn't parseable.
    func cycleKey(for scope: Scope, accountID: String, sections: [UsageSection], now: Date) -> String {
        let detailStr = detail(in: sections, scope: scope)
        if !detailStr.isEmpty, let resets = Date.parseClaudeReset(detailStr, now: now) {
            return String(Int(resets.timeIntervalSince1970))
        }

        let anchorKey: String
        let windowSeconds: TimeInterval
        switch scope {
        case .session:
            anchorKey = AccountKeys.key(Self.cycleStartFamily, accountID, "session")
            windowSeconds = 5 * 3600
        case .weekly:
            anchorKey = AccountKeys.key(Self.cycleStartFamily, accountID, "weekly")
            windowSeconds = 7 * 24 * 3600
        }
        let stored = UserDefaults.standard.double(forKey: anchorKey)
        let nowTS = now.timeIntervalSince1970
        if stored <= 0 || (nowTS - stored) >= windowSeconds {
            UserDefaults.standard.set(nowTS, forKey: anchorKey)
            return String(Int(nowTS))
        }
        return String(Int(stored))
    }

    // MARK: - Percentage / detail extraction

    private func percentage(in sections: [UsageSection], scope: Scope) -> Int? {
        switch scope {
        case .session:
            for section in sections {
                for meter in section.meters where meter.label.lowercased().contains("current session") {
                    return meter.percentage
                }
            }
        case .weekly:
            for section in sections where section.title.lowercased().contains("weekly") {
                for meter in section.meters {
                    let l = meter.label.lowercased()
                    if l == "weekly" || l == "weekly usage" || l.hasPrefix("weekly usage") {
                        return meter.percentage
                    }
                }
                if let first = section.meters.first { return first.percentage }
            }
        }
        return nil
    }

    private func detail(in sections: [UsageSection], scope: Scope) -> String {
        switch scope {
        case .session:
            for section in sections {
                for meter in section.meters where meter.label.lowercased().contains("current session") {
                    return meter.detail
                }
            }
        case .weekly:
            for section in sections where section.title.lowercased().contains("weekly") {
                for meter in section.meters {
                    let l = meter.label.lowercased()
                    if l == "weekly" || l == "weekly usage" || l.hasPrefix("weekly usage") {
                        return meter.detail
                    }
                }
                if let first = section.meters.first { return first.detail }
            }
        }
        return ""
    }

    // MARK: - Stale key cleanup

    /// Drop notif.fired.* / notif.snoozed.* / notif.lastPct.* entries whose
    /// embedded cycle timestamp is more than 14 days old. Without this the
    /// UserDefaults plist would grow unbounded over months. Covers both the
    /// v2.7.1 keys and the per-account keys: the account ID sits in the middle
    /// ("notif.fired.<accountId>.session.50.<cycle>"), so the cycle timestamp
    /// is still the trailing component.
    private func pruneStaleKeys() {
        let cutoff = Date().timeIntervalSince1970 - (14 * 24 * 3600)
        let defaults = UserDefaults.standard
        let prefixes = ["notif.fired.", "notif.snoozed.", "notif.lastPct."]
        for (key, _) in defaults.dictionaryRepresentation() {
            guard prefixes.contains(where: { key.hasPrefix($0) }) else { continue }
            // Cycle key is the trailing dot-separated component; parse as Int seconds.
            if let lastDot = key.lastIndex(of: "."), let ts = Double(key[key.index(after: lastDot)...]) {
                if ts < cutoff {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.snoozeActionID {
            let info = response.notification.request.content.userInfo
            if let scope = info["scope"] as? String, let cycleKey = info["cycleKey"] as? String {
                // Notifications delivered by v2.7.1 carry no accountID; they
                // can only belong to the primary account.
                let accountID = info["accountID"] as? String ?? AccountRecord.primaryID
                let key = AccountKeys.key(Self.snoozedFamily, accountID, "\(scope).\(cycleKey)")
                UserDefaults.standard.set(true, forKey: key)
            }
        }
        completionHandler()
    }
}

// MARK: - Usage Forecast (EWMA burn rate + ETA)

struct UsageForecast {
    enum State {
        case ok
        case idle
        case insufficientData
        case willNotExhaust
    }

    let ratePerHour: Double
    let etaDate: Date?
    let state: State

    /// Pure value computation. EWMA over inter-sample slopes (alpha = 0.3:
    /// weights recent slopes a few samples deep without overfitting one tick).
    /// Pass `windowSeconds` to limit how far back to look (e.g. session uses
    /// the last 30 min slice; weekly uses the full retention window).
    static func compute(
        samples: [UsageHistory.Sample],
        currentPct: Int,
        resetAt: Date,
        windowSeconds: TimeInterval,
        minSpanSeconds: TimeInterval,
        keyPath: KeyPath<UsageHistory.Sample, Int>,
        now: Date = Date()
    ) -> UsageForecast {
        let cutoff = now.timeIntervalSince1970 - windowSeconds
        let window = samples.filter { $0.t >= cutoff }

        guard window.count >= 3 else {
            return UsageForecast(ratePerHour: 0, etaDate: nil, state: .insufficientData)
        }
        let span = window.last!.t - window.first!.t
        guard span >= minSpanSeconds else {
            return UsageForecast(ratePerHour: 0, etaDate: nil, state: .insufficientData)
        }

        // alpha = 0.3 favours the last ~3-5 slopes; small enough to ride out
        // a single jittery sample, large enough to react inside one window.
        let alpha = 0.3
        var ewma: Double? = nil
        for i in 1..<window.count {
            let dt = window[i].t - window[i - 1].t
            guard dt > 0 else { continue }
            let dPct = Double(window[i][keyPath: keyPath] - window[i - 1][keyPath: keyPath])
            let slope = dPct / (dt / 3600.0)
            if let prev = ewma {
                ewma = alpha * slope + (1 - alpha) * prev
            } else {
                ewma = slope
            }
        }
        let rate = ewma ?? 0

        if rate <= 0.05 {
            return UsageForecast(ratePerHour: rate, etaDate: nil, state: .idle)
        }

        let remaining = max(0, 100 - currentPct)
        let hoursToExhaust = Double(remaining) / rate
        let eta = now.addingTimeInterval(hoursToExhaust * 3600)

        if eta >= resetAt {
            return UsageForecast(ratePerHour: rate, etaDate: nil, state: .willNotExhaust)
        }
        return UsageForecast(ratePerHour: rate, etaDate: eta, state: .ok)
    }
}

// MARK: - Reset-time parsing

extension Date {
    /// Parses Claude usage-card reset strings. Handles "Resets at 3:42pm",
    /// "Resets Wed 9am", and "Resets in 2h" forms. Returns nil if unparseable
    /// so the caller can fall back to a sensible default.
    static func parseClaudeReset(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let lower = text.lowercased()

        // Relative "in Nh Mm" / "in N hr M min" / "in Nh" / "in Nm" forms.
        // Combine hours + minutes when both appear so "4 hr 11 min" anchors at
        // 4h11m, not 4h flat.
        if let inRange = lower.range(of: #"in\s+"#, options: .regularExpression) {
            let tail = String(lower[inRange.upperBound...])
            let hourRe = try? NSRegularExpression(pattern: #"(\d+)\s*h"#, options: [])
            let minRe = try? NSRegularExpression(pattern: #"(\d+)\s*m(?:in)?\b"#, options: [])
            let ns = tail as NSString
            var hours = 0
            var minutes = 0
            if let m = hourRe?.firstMatch(in: tail, range: NSRange(location: 0, length: ns.length)) {
                hours = Int(ns.substring(with: m.range(at: 1))) ?? 0
            }
            if let m = minRe?.firstMatch(in: tail, range: NSRange(location: 0, length: ns.length)) {
                minutes = Int(ns.substring(with: m.range(at: 1))) ?? 0
            }
            if hours > 0 || minutes > 0 {
                return now.addingTimeInterval(TimeInterval(hours) * 3600 + TimeInterval(minutes) * 60)
            }
        }

        // Time-of-day: "3:42pm", "9am", "3pm"
        let timeRe = try? NSRegularExpression(pattern: #"(\d{1,2})(?::(\d{2}))?\s*(am|pm)"#, options: [])
        let ns = lower as NSString
        let match = timeRe?.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length))

        // Weekday (mon/tue/...) optionally precedes the time
        let weekdayMap: [String: Int] = [
            "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7
        ]
        var targetWeekday: Int? = nil
        for (k, v) in weekdayMap where lower.contains(k) { targetWeekday = v; break }

        // Month + day forms ("Jun 1", "January 5"). Used for billing-style
        // resets (Extra usage). Returns the next future occurrence.
        let monthMap: [String: Int] = [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
        ]
        var targetMonth: Int? = nil
        var targetDay: Int? = nil
        if let monthRe = try? NSRegularExpression(
            pattern: #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+(\d{1,2})\b"#,
            options: []),
           let mm = monthRe.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)) {
            let monthKey = ns.substring(with: mm.range(at: 1))
            targetMonth = monthMap[monthKey]
            targetDay = Int(ns.substring(with: mm.range(at: 2)))
        }

        guard let m = match else {
            // No time-of-day. Prefer month+day, then weekday.
            if let mo = targetMonth, let d = targetDay {
                return nextDate(month: mo, day: d, hour: 0, minute: 0, after: now, calendar: calendar)
            }
            if let wd = targetWeekday {
                return nextDate(weekday: wd, hour: 0, minute: 0, after: now, calendar: calendar)
            }
            return nil
        }

        let hour = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let minute = m.range(at: 2).location != NSNotFound
            ? (Int(ns.substring(with: m.range(at: 2))) ?? 0) : 0
        let ampm = ns.substring(with: m.range(at: 3))
        var h24 = hour % 12
        if ampm == "pm" { h24 += 12 }

        if let mo = targetMonth, let d = targetDay {
            return nextDate(month: mo, day: d, hour: h24, minute: minute, after: now, calendar: calendar)
        }
        if let wd = targetWeekday {
            return nextDate(weekday: wd, hour: h24, minute: minute, after: now, calendar: calendar)
        }
        return nextTimeOfDay(hour: h24, minute: minute, after: now, calendar: calendar)
    }

    private static func nextDate(month: Int, day: Int, hour: Int, minute: Int, after: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year], from: after)
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        guard var candidate = calendar.date(from: comps) else { return after }
        if candidate <= after {
            comps.year = (comps.year ?? 0) + 1
            candidate = calendar.date(from: comps) ?? candidate
        }
        return candidate
    }

    private static func nextTimeOfDay(hour: Int, minute: Int, after: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: after)
        comps.hour = hour
        comps.minute = minute
        guard var candidate = calendar.date(from: comps) else { return after }
        if candidate <= after {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    private static func nextDate(weekday: Int, hour: Int, minute: Int, after: Date, calendar: Calendar) -> Date {
        var comps = DateComponents()
        comps.weekday = weekday
        comps.hour = hour
        comps.minute = minute
        return calendar.nextDate(after: after, matching: comps, matchingPolicy: .nextTime) ?? after
    }
}

// MARK: - Native Usage View

// MARK: - Multi-Account Popover

/// NSScrollView that hands scroll-wheel events to the enclosing scroll view
/// when `passesScrollToParent` is set: a usage view embedded in the
/// multi-account popover is pinned to its content height, so the outer view
/// does the scrolling.
final class PassthroughScrollView: NSScrollView {
    var passesScrollToParent = false
    override func scrollWheel(with event: NSEvent) {
        if passesScrollToParent {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Popover content for two or more accounts. One section per account: a
/// header (name; org or email; plan tier) above that account's own
/// UsageContentView, or a compact "Signed out" row with a Sign In Again
/// button instead of stale numbers. Sections stack in one scroll view; each
/// embedded usage view is pinned to its content height and the total is
/// reported through onContentSizeChanged, so the popover fits every account.
final class MultiAccountUsageView: NSView {
    struct Entry {
        let accountID: String
        let title: String
        let detail: String?
        let signedOut: Bool
        let usageView: UsageContentView
    }

    var onContentSizeChanged: ((CGFloat) -> Void)?
    var onSignInAgain: ((String) -> Void)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var emitScheduled = false

    private final class Section {
        let accountID: String
        let titleLabel: NSTextField
        let detailLabel: NSTextField
        let signedOutRow: NSView
        let usageView: UsageContentView
        let usageHeight: NSLayoutConstraint
        var arranged: [NSView] = []
        init(accountID: String, titleLabel: NSTextField, detailLabel: NSTextField,
             signedOutRow: NSView, usageView: UsageContentView, usageHeight: NSLayoutConstraint) {
            self.accountID = accountID
            self.titleLabel = titleLabel
            self.detailLabel = detailLabel
            self.signedOutRow = signedOutRow
            self.usageView = usageView
            self.usageHeight = usageHeight
        }
    }
    private var sections: [Section] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0x1a/255.0, green: 0x1a/255.0, blue: 0x1a/255.0, alpha: 1).cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        scrollView.documentView = stack

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Total height of all sections at their content heights.
    var contentHeight: CGFloat {
        stack.layoutSubtreeIfNeeded()
        return stack.fittingSize.height
    }

    /// Per-section state, read by the QA test hooks.
    var sectionStates: [(accountID: String, showsUsage: Bool, usageHeight: CGFloat)] {
        sections.map { ($0.accountID, !$0.usageView.isHidden, $0.usageHeight.constant) }
    }

    /// Same accounts in the same order: update headers and signed-out rows in
    /// place. Otherwise rebuild the sections (embedded views are reused).
    func reload(_ entries: [Entry]) {
        if entries.map({ $0.accountID }) == sections.map({ $0.accountID }) {
            for (section, entry) in zip(sections, entries) { apply(entry, to: section) }
        } else {
            rebuild(entries)
        }
        scheduleEmit()
    }

    /// Detaches every embedded usage view (before the popover goes back to
    /// a single account's view).
    func detachAll() {
        rebuild([])
    }

    func scrollToTop() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let doc = self.scrollView.documentView else { return }
            doc.scroll(NSPoint(x: 0, y: doc.bounds.height))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    private func rebuild(_ entries: [Entry]) {
        for section in sections {
            section.usageHeight.isActive = false
            section.usageView.onContentSizeChanged = nil
        }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sections.removeAll()

        for (i, entry) in entries.enumerated() {
            var arranged: [NSView] = []
            if i > 0 {
                let divider = NSView()
                divider.wantsLayer = true
                divider.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                arranged.append(divider)
            }

            let title = label(entry.title, size: 13, weight: .semibold, color: .white)
            let detail = label("", size: 11, weight: .regular, color: NSColor(white: 0.55, alpha: 1))
            let header = NSStackView(views: [title, detail])
            header.orientation = .vertical
            header.alignment = .leading
            header.spacing = 1
            header.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 0, right: 28)
            arranged.append(header)

            let signedOutLabel = label("Signed out", size: 12, weight: .regular, color: NSColor(white: 0.7, alpha: 1))
            let button = NSButton(title: "Sign In Again\u{2026}", target: self, action: #selector(signInAgainPressed(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier(entry.accountID)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [signedOutLabel, spacer, button])
            row.orientation = .horizontal
            row.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 10, right: 16)
            arranged.append(row)

            let usage = entry.usageView
            usage.removeFromSuperview()
            usage.isEmbedded = true
            usage.translatesAutoresizingMaskIntoConstraints = false
            let height = usage.heightAnchor.constraint(equalToConstant: max(usage.skeletonHeight, 60))
            height.isActive = true
            arranged.append(usage)

            for view in arranged {
                stack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            let section = Section(accountID: entry.accountID, titleLabel: title, detailLabel: detail,
                                  signedOutRow: row, usageView: usage, usageHeight: height)
            section.arranged = arranged
            usage.onContentSizeChanged = { [weak self, weak section] h in
                guard let self = self, let section = section else { return }
                if abs(section.usageHeight.constant - h) > 0.5 {
                    section.usageHeight.constant = h
                }
                self.scheduleEmit()
            }
            sections.append(section)
            apply(entry, to: section)
        }
    }

    private func apply(_ entry: Entry, to section: Section) {
        if section.titleLabel.stringValue != entry.title { section.titleLabel.stringValue = entry.title }
        let detail = entry.detail ?? ""
        if section.detailLabel.stringValue != detail { section.detailLabel.stringValue = detail }
        section.detailLabel.isHidden = detail.isEmpty
        section.signedOutRow.isHidden = !entry.signedOut
        section.usageView.isHidden = entry.signedOut
    }

    /// Coalesces height reports from all sections into one callback.
    private func scheduleEmit() {
        guard !emitScheduled else { return }
        emitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.emitScheduled = false
            let total = self.contentHeight
            NSLog("%@", "[ClaudeMeter] popover sizing(multi): sections=\(self.sections.count) total=\(total)")
            self.onContentSizeChanged?(total)
        }
    }

    @objc private func signInAgainPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onSignInAgain?(id)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}

class UsageContentView: NSView {
    private let scrollView = PassthroughScrollView()
    /// True inside the multi-account popover: the view is pinned to its
    /// content height, scrolling is left to the outer view and the vertical
    /// scroller is hidden. False (the default) is the single-account popover.
    var isEmbedded = false {
        didSet {
            guard oldValue != isEmbedded else { return }
            scrollView.passesScrollToParent = isEmbedded
            scrollView.hasVerticalScroller = !isEmbedded
        }
    }
    private let stackView = NSStackView()
    private let statusDot = NSView()
    var onContentSizeChanged: ((CGFloat) -> Void)?
    private var pendingScrollToTop = false
    var planTierDisplayName: String? {
        didSet {
            guard oldValue != planTierDisplayName else { return }
            // Force a re-render so the section header picks up the new tier.
            update(sections: lastSections,
                   sessionForecast: lastSessionForecast,
                   weeklyForecast: lastWeeklyForecast,
                   sessionResetAt: lastSessionResetAt,
                   weeklyResetAt: lastWeeklyResetAt,
                   history: lastHistory)
        }
    }
    /// v2.7 — Burn-rate chip visibility. The chip + sparkline are always
    /// allocated for eligible rows (just hidden when off), so toggling
    /// re-applies via applyInPlace and skips the doUpdate early-return.
    var showBurnRate: Bool = true {
        didSet {
            guard oldValue != showBurnRate else { return }
            reapplyVisibilityToRenderedRows()
        }
    }
    var showSparkline: Bool = true {
        didSet {
            guard oldValue != showSparkline else { return }
            reapplyVisibilityToRenderedRows()
        }
    }
    private func reapplyVisibilityToRenderedRows() {
        guard !lastSections.isEmpty,
              renderedSections.count == lastSections.count else { return }
        applyInPlace(sections: lastSections)
        // Row heights may change (sparkline 22pt; rate-chip negligible);
        // re-emit so the popover re-fits.
        DispatchQueue.main.async { [weak self] in
            self?.emitContentSize(label: "v2.7-toggle")
        }
    }
    private var skeletonShownAt: Date?
    private static let minSkeletonDuration: TimeInterval = 0.6
    private var lastSections: [UsageSection] = []
    private var lastSessionForecast: UsageForecast?
    private var lastWeeklyForecast: UsageForecast?
    private var lastHistory: UsageHistory?
    private var lastSessionResetAt: Date?
    private var lastWeeklyResetAt: Date?
    let countdownTicker = CountdownTicker()

    // In-place update bookkeeping. When the structural shape of the data
    // (section titles + ordered meter labels per section) is unchanged across
    // refreshes, we mutate the existing row views — animating bar fills and
    // swapping label text — instead of tearing down and recreating the view
    // tree. The crossfade rebuild path stays for shape changes and the
    // skeleton-to-content transition.
    private struct MeterRowViews {
        let nameLabel: NSTextField
        let flameView: NSImageView
        let rateLabel: NSTextField
        let pctLabel: NSTextField
        let fill: NSView
        let fillWidth: NSLayoutConstraint
        let trackBarWidth: CGFloat
        let sparkline: SparklineView?
        let detailLabel: NSTextField
        let countdownLabel: NSTextField
        var meter: UsageMeter
    }
    private struct SectionViews {
        let title: String
        let titleLabel: NSTextField?
        var rows: [MeterRowViews]
    }
    private struct SectionKey: Equatable {
        let title: String
        let meterLabels: [String]
    }
    private var renderedSections: [SectionViews] = []
    private var structuralKey: [SectionKey] = []

    /// True when the view has real usage data (not skeleton or empty).
    var hasContent: Bool { !lastSections.isEmpty }

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
        update(sections: sections, sessionForecast: nil, weeklyForecast: nil,
               sessionResetAt: nil, weeklyResetAt: nil, history: nil)
    }

    func update(sections: [UsageSection],
                sessionForecast: UsageForecast?,
                weeklyForecast: UsageForecast?,
                sessionResetAt: Date?,
                weeklyResetAt: Date?,
                history: UsageHistory? = nil) {
        // If skeleton is still showing, ensure minimum display time
        if let shown = skeletonShownAt {
            let elapsed = Date().timeIntervalSince(shown)
            let remaining = Self.minSkeletonDuration - elapsed
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    self?.doUpdate(sections: sections,
                                   sessionForecast: sessionForecast,
                                   weeklyForecast: weeklyForecast,
                                   sessionResetAt: sessionResetAt,
                                   weeklyResetAt: weeklyResetAt,
                                   history: history)
                }
                return
            }
        }
        doUpdate(sections: sections,
                 sessionForecast: sessionForecast,
                 weeklyForecast: weeklyForecast,
                 sessionResetAt: sessionResetAt,
                 weeklyResetAt: weeklyResetAt,
                 history: history)
    }

    private func doUpdate(sections: [UsageSection],
                          sessionForecast: UsageForecast?,
                          weeklyForecast: UsageForecast?,
                          sessionResetAt: Date?,
                          weeklyResetAt: Date?,
                          history: UsageHistory?) {
        let wasShowingSkeleton = skeletonShownAt != nil
        skeletonShownAt = nil

        // Skip full rebuild if the data hasn't changed (unless transitioning
        // from skeleton) — avoids layout churn that causes popover flicker.
        // v2.7.1 — also bypass the short-circuit when the history buffer
        // grew (sparkline needs the new sample) so stable-percentage
        // refreshes still advance the chart.
        let prevSampleCount = lastHistory?.samples.count ?? 0
        let newSampleCount = history?.samples.count ?? 0
        let historyGrew = newSampleCount != prevSampleCount
        if !wasShowingSkeleton
            && sections == lastSections
            && forecastsEqual(sessionForecast, lastSessionForecast)
            && forecastsEqual(weeklyForecast, lastWeeklyForecast)
            && !historyGrew {
            return
        }
        lastSections = sections
        lastSessionForecast = sessionForecast
        lastWeeklyForecast = weeklyForecast
        lastSessionResetAt = sessionResetAt
        lastWeeklyResetAt = weeklyResetAt
        lastHistory = history

        // Choose between in-place updates (when the rendered shape — section
        // titles + ordered meter labels — matches the new data) and a full
        // rebuild. In-place avoids the visible flicker of recreating every
        // view on every refresh and lets us tween bar widths.
        let newKey = sections.map { section in
            SectionKey(title: section.title, meterLabels: section.meters.map { $0.label })
        }
        let canApplyInPlace = !wasShowingSkeleton
            && !sections.isEmpty
            && newKey == structuralKey
            && renderedSections.count == sections.count

        // PARKED v2.5: the burn-rate / ETA headline is intentionally not
        // rendered. v2.7 reuses sessionForecast / weeklyForecast for the
        // per-row burn-rate chip via applyMeterRow's lookup of
        // lastSessionForecast / lastWeeklyForecast (already stored above).
        // The resetAt args are still latched on the view in case future
        // surfaces need them.
        _ = (sessionResetAt, weeklyResetAt)

        if canApplyInPlace {
            applyInPlace(sections: sections)
            // One post-layout tick is enough on the in-place path: the view
            // tree is unchanged, so heights only shift if a detail/countdown
            // toggled visibility. Skip the +0.35s tick that exists for the
            // popover-resize race during full rebuilds.
            emitContentSize(label: "in-place")
            DispatchQueue.main.async { [weak self] in
                self?.emitContentSize(label: "in-place-post")
            }
            return
        }

        // Full rebuild: tear down and recreate, capturing view refs into
        // renderedSections so the next compatible update can take the
        // in-place path.
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        countdownTicker.clearRegistrations()
        renderedSections.removeAll()
        structuralKey.removeAll()

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

            // Section title. The "plan usage" section gets the resolved plan
            // tier appended (e.g. "PLAN USAGE LIMITS - Pro").
            var titleLabel: NSTextField? = nil
            if !section.title.isEmpty {
                let title = makeLabel(sectionTitleText(for: section), size: 10, weight: .semibold,
                                      color: NSColor(white: 0.5, alpha: 1))
                title.allowsDefaultTighteningForTruncation = true
                stackView.addArrangedSubview(title)
                stackView.setCustomSpacing(6, after: title)
                titleLabel = title
            }

            var rows: [MeterRowViews] = []
            rows.reserveCapacity(section.meters.count)
            for meter in section.meters {
                rows.append(createMeterRow(meter))
            }
            renderedSections.append(SectionViews(title: section.title, titleLabel: titleLabel, rows: rows))
        }
        structuralKey = newKey

        // Crossfade from skeleton to real content
        if wasShowingSkeleton {
            scrollView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.animator().alphaValue = 1
            }
        }

        // Initial measurement is unreliable: at first doUpdate the scrollView
        // hasn't been given its real width yet, so labels can't compute wrapped
        // heights and fittingSize under-reports. Report the best we have now,
        // then re-measure on the next runloop tick once layout has settled
        // and again after a brief delay (enough for the popover resize
        // animation to bring the scrollView width up).
        emitContentSize(label: "initial")
        DispatchQueue.main.async { [weak self] in
            self?.emitContentSize(label: "post-layout")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.emitContentSize(label: "post-animation")
            self?.applyPendingScrollToTopIfNeeded()
        }
    }

    /// Mutate already-rendered rows to match `sections`. Caller must have
    /// verified that the structural key still matches.
    private func applyInPlace(sections: [UsageSection]) {
        for (i, section) in sections.enumerated() {
            // Section titles are stable across in-place updates except when
            // the resolved plan tier suffix changes; recompute and assign.
            if let titleLabel = renderedSections[i].titleLabel {
                let titleText = sectionTitleText(for: section)
                if titleLabel.stringValue != titleText {
                    titleLabel.stringValue = titleText
                }
            }
            for (j, meter) in section.meters.enumerated() {
                applyMeterRow(views: &renderedSections[i].rows[j], meter: meter, animated: true)
            }
        }
    }

    private func sectionTitleText(for section: UsageSection) -> String {
        let upper = section.title.uppercased()
        // The plan tier (Pro / Max 20x / etc.) gates the session window, so
        // we render the chip on whichever section header refers to the plan
        // or session limit. Old DOM-scraped pages used "Plan limits"; the
        // current JSON normalizer emits "Session limit" — both qualify.
        let lower = section.title.lowercased()
        let isPlanSection = lower.contains("plan") || lower.contains("session")
        if isPlanSection, let tier = planTierDisplayName, !tier.isEmpty {
            return "\(upper) - \(tier.uppercased())"
        }
        return upper
    }

    // MARK: - Loading Skeleton

    func showLoadingSkeleton() {
        skeletonShownAt = Date()
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        countdownTicker.clearRegistrations()
        renderedSections.removeAll()
        structuralKey.removeAll()
        let barWidth: CGFloat = 368

        // Headline shimmer rows are intentionally omitted to match the v2.5
        // layout, where the burn-rate / ETA headline is parked. Re-add two
        // 14pt shimmer bars here when the headline is unparked so the
        // skeleton-to-content crossfade lines up cleanly.

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
        anim.duration = 2.0
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradient.add(anim, forKey: "shimmer")

        return view
    }

    /// Build a meter row, capture references to its mutable subviews, and
    /// add it to the main stack. All four arranged subviews (name row, track,
    /// detail label, countdown label) are always added; visibility is toggled
    /// per state. Returns a `MeterRowViews` whose contents the in-place update
    /// path can mutate without rebuilding.
    private func createMeterRow(_ meter: UsageMeter) -> MeterRowViews {
        let barWidth: CGFloat = 368

        // Label row
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .firstBaseline
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: barWidth).isActive = true

        let name = makeLabel(meter.label.isEmpty ? "Usage" : meter.label, size: 13, weight: .medium, color: .white)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(name)

        // Flame icon is always present so we can toggle peak-hours visibility
        // in place. NSStackView.detachesHiddenViews drops it from the layout
        // when hidden, so it costs nothing visually until needed.
        let flame = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        flame.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "peak hours")?
            .withSymbolConfiguration(cfg)
        flame.contentTintColor = NSColor(red: 0xc0/255.0, green: 0x5e/255.0, blue: 0x1a/255.0, alpha: 1)
        flame.translatesAutoresizingMaskIntoConstraints = false
        flame.setContentHuggingPriority(.required, for: .horizontal)
        flame.setContentCompressionResistancePriority(.required, for: .horizontal)
        flame.isHidden = true
        row.addArrangedSubview(flame)

        // Burn-rate chip (v2.7). Renders e.g. "+4.2%/h" between flame and pct,
        // colored by rate magnitude. Hidden until a forecast lands; collapses
        // out of layout via detachesHiddenViews so the row stays the same
        // height as before when the chip is off.
        let rate = makeLabel("", size: 11, weight: .medium,
                              color: NSColor(white: 0.55, alpha: 1))
        rate.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        rate.alignment = .right
        rate.setContentHuggingPriority(.required, for: .horizontal)
        rate.setContentCompressionResistancePriority(.required, for: .horizontal)
        rate.isHidden = true
        row.addArrangedSubview(rate)

        let pct = makeLabel("\(meter.percentage)%", size: 13, weight: .medium,
                            color: colorForPercentage(meter.percentage))
        pct.alignment = .right
        pct.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(pct)

        stackView.addArrangedSubview(row)
        stackView.setCustomSpacing(4, after: row)

        // Progress bar. The fill uses a constant width constraint (rather
        // than a multiplier on track width) so the in-place update path can
        // animate it via NSAnimationContext — multiplier constants are
        // immutable on NSLayoutConstraint and would otherwise force a
        // constraint swap on every tick.
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
        let initialFraction = max(CGFloat(min(meter.percentage, 100)) / 100.0, 0.01)
        let fillWidth = fill.widthAnchor.constraint(equalToConstant: barWidth * initialFraction)
        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fillWidth,
        ])

        stackView.addArrangedSubview(track)
        stackView.setCustomSpacing(2, after: track)

        // Sparkline (v2.7) — only for the two aggregate meters that have
        // useful 24h history dimension (session/weekly). Per-model meters
        // skip allocation: their pct is too noisy at the 24h scope to be
        // visually informative right now.
        var sparkline: SparklineView? = nil
        let lower = meter.label.lowercased()
        let isAggregateSession = lower.contains("current session")
        let isAggregateWeekly = lower == "weekly usage"
        if isAggregateSession || isAggregateWeekly {
            let sv = SparklineView(barWidth: barWidth)
            sv.translatesAutoresizingMaskIntoConstraints = false
            sv.heightAnchor.constraint(equalToConstant: 22).isActive = true
            sv.widthAnchor.constraint(equalToConstant: barWidth).isActive = true
            sv.isHidden = !showSparkline
            stackView.addArrangedSubview(sv)
            stackView.setCustomSpacing(2, after: sv)
            sparkline = sv
        }

        // Detail and countdown labels are always added; visibility is the
        // signal. NSStackView's detachesHiddenViews makes hidden labels
        // collapse out of the layout, so the visual result matches the old
        // conditional-add behavior while preserving stable view identity.
        let detail = makeLabel("", size: 11, color: NSColor(white: 0.45, alpha: 1))
        detail.isHidden = true
        stackView.addArrangedSubview(detail)
        stackView.setCustomSpacing(2, after: detail)

        let countdown = makeLabel("", size: 10, color: NSColor(white: 0.45, alpha: 1))
        countdown.isHidden = true
        stackView.addArrangedSubview(countdown)
        stackView.setCustomSpacing(6, after: countdown)

        var views = MeterRowViews(
            nameLabel: name,
            flameView: flame,
            rateLabel: rate,
            pctLabel: pct,
            fill: fill,
            fillWidth: fillWidth,
            trackBarWidth: barWidth,
            sparkline: sparkline,
            detailLabel: detail,
            countdownLabel: countdown,
            meter: meter
        )
        applyMeterRow(views: &views, meter: meter, animated: false)
        return views
    }

    /// Mutate an existing meter row to match `meter`. When `animated`, the
    /// progress fill width and color tween over 0.4s; everything else snaps.
    /// Returns the updated `MeterRowViews` (`meter` field rewritten).
    private func applyMeterRow(views: inout MeterRowViews, meter: UsageMeter, animated: Bool) {
        let lower = meter.label.lowercased()
        let isCurrentSession = lower.contains("current session")
        let isAggregateWeekly = lower == "weekly usage"
        let showFlame = isCurrentSession && AppDelegate.isInPeakWindow()

        let nameValue = meter.label.isEmpty ? "Usage" : meter.label
        if views.nameLabel.stringValue != nameValue { views.nameLabel.stringValue = nameValue }

        views.flameView.isHidden = !showFlame
        if showFlame {
            views.flameView.toolTip = Self.peakTooltipPublic()
            countdownTicker.registerFlameIfMissing(views.flameView)
        }

        // Burn-rate chip (v2.7) — populated from the forecast EWMA. Hidden
        // when the chip pref is off, when the meter isn't an aggregate
        // session/weekly window, or when the forecast hasn't accumulated
        // enough samples (state == .insufficientData / .idle).
        let forecast: UsageForecast? = isCurrentSession ? lastSessionForecast
                                       : isAggregateWeekly ? lastWeeklyForecast
                                       : nil
        applyBurnRateChip(label: views.rateLabel, forecast: forecast)

        // Sparkline (v2.7) — pull samples for the matching scope. Hidden
        // when the user toggled it off or when too few samples are present.
        if let sv = views.sparkline {
            sv.isHidden = !showSparkline
            if showSparkline, let history = lastHistory {
                let samples: [(t: TimeInterval, pct: Int)]
                if isCurrentSession {
                    samples = history.samples.map { ($0.t, $0.s) }
                } else {
                    samples = history.samples.map { ($0.t, $0.w) }
                }
                sv.setData(samples: samples,
                           color: colorForPercentage(meter.percentage))
            }
        }

        let pctText = "\(meter.percentage)%"
        let pctColor = colorForPercentage(meter.percentage)
        if views.pctLabel.stringValue != pctText { views.pctLabel.stringValue = pctText }
        views.pctLabel.textColor = pctColor

        // Fill width
        let fraction = max(CGFloat(min(meter.percentage, 100)) / 100.0, 0.01)
        let newWidth = views.trackBarWidth * fraction
        if abs(views.fillWidth.constant - newWidth) > 0.5 {
            if animated {
                // Force pending layout to settle so the animator sees a clean
                // baseline; otherwise constraint-constant animations on macOS
                // can snap straight to the new value when the parent has
                // pending layout invalidation.
                views.fill.superview?.layoutSubtreeIfNeeded()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.4
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    ctx.allowsImplicitAnimation = true
                    views.fillWidth.animator().constant = newWidth
                    views.fill.superview?.layoutSubtreeIfNeeded()
                }
            } else {
                views.fillWidth.constant = newWidth
            }
        }

        // Fill color
        if let layer = views.fill.layer {
            let newColor = pctColor.cgColor
            if layer.backgroundColor != newColor {
                if animated {
                    let anim = CABasicAnimation(keyPath: "backgroundColor")
                    anim.fromValue = layer.backgroundColor
                    anim.toValue = newColor
                    anim.duration = 0.4
                    anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.add(anim, forKey: "fillColor")
                }
                layer.backgroundColor = newColor
            }
        }

        // Detail label. Reset-prefixed details are absorbed by the live
        // countdown row, matching the original conditional render.
        let lowerDetail = meter.detail.lowercased()
        let detailIsReset = lowerDetail.hasPrefix("resets")
        let suppressDetail = detailIsReset && meter.resetAt != nil
        let showDetail = !meter.detail.isEmpty && !suppressDetail
        if showDetail && views.detailLabel.stringValue != meter.detail {
            views.detailLabel.stringValue = meter.detail
        }
        views.detailLabel.isHidden = !showDetail

        // Countdown registration. `register` is idempotent (replaces by label),
        // so we can call it on every refresh without churning the entries
        // array. `unregister` clears the row when resetAt becomes nil.
        if let resetAt = meter.resetAt {
            let isEstimate = meter.detail.isEmpty
            let prefixOverride = detailIsReset ? Self.formatResetPrefix(resetAt) : nil
            countdownTicker.register(label: views.countdownLabel,
                                     resetAt: resetAt,
                                     isEstimate: isEstimate,
                                     prefix: prefixOverride)
        } else {
            countdownTicker.unregister(views.countdownLabel)
            views.countdownLabel.isHidden = true
        }

        views.meter = meter
    }

    /// v2.7 — Render the burn-rate chip from the precomputed EWMA forecast.
    /// Hidden when the user toggled the chip off, when the meter has no
    /// matching forecast (per-model windows currently), or when the
    /// forecast is in a noise-floor state (insufficientData / idle).
    private func applyBurnRateChip(label: NSTextField, forecast: UsageForecast?) {
        guard showBurnRate, let f = forecast else {
            label.isHidden = true
            return
        }
        switch f.state {
        case .insufficientData, .idle:
            label.isHidden = true
            return
        case .ok, .willNotExhaust:
            break
        }
        let rate = f.ratePerHour
        // Format: "+4.2%/h", with one decimal under 10 and zero decimals at
        // higher rates so the chip never grows wider than ~50 pts.
        let formatted: String
        if rate >= 10 {
            formatted = String(format: "+%.0f%%/h", rate)
        } else {
            formatted = String(format: "+%.1f%%/h", rate)
        }
        let color: NSColor
        switch rate {
        case ..<1.0:   color = NSColor(red: 0x2b/255.0, green: 0xa8/255.0, blue: 0x82/255.0, alpha: 1) // green
        case ..<5.0:   color = NSColor(red: 0xc9/255.0, green: 0xa6/255.0, blue: 0x2c/255.0, alpha: 1) // gold
        case ..<15.0:  color = NSColor(red: 0xc0/255.0, green: 0x5e/255.0, blue: 0x1a/255.0, alpha: 1) // amber
        default:       color = NSColor(red: 0xc0/255.0, green: 0x3a/255.0, blue: 0x3a/255.0, alpha: 1) // crimson
        }
        if label.stringValue != formatted { label.stringValue = formatted }
        label.textColor = color
        label.toolTip = "EWMA burn rate over recent samples"
        label.isHidden = false
    }

    private static func formatResetPrefix(_ resetAt: Date, now: Date = Date()) -> String {
        let remaining = resetAt.timeIntervalSince(now)
        let f = DateFormatter()
        if remaining < 24 * 3600 {
            f.timeStyle = .short
            f.dateStyle = .none
        } else if remaining < 7 * 24 * 3600 {
            f.dateFormat = "EEE h:mm a"
        } else {
            f.dateFormat = "MMM d"
        }
        return "Resets \(f.string(from: resetAt))"
    }

    // MARK: - Status Dot

    func setStatusFresh(_ fresh: Bool) {
        statusDot.layer?.backgroundColor = fresh
            ? NSColor(red: 0x2b/255.0, green: 0xa8/255.0, blue: 0x82/255.0, alpha: 1).cgColor
            : NSColor.gray.cgColor
    }

    func setStatusLoading() {
        statusDot.layer?.backgroundColor = NSColor(red: 0xc0/255.0, green: 0x96/255.0, blue: 0x3a/255.0, alpha: 1).cgColor
    }

    // MARK: - Countdown Ticker (popover-only)

    func startCountdownTicker() {
        countdownTicker.start()
    }

    func stopCountdownTicker() {
        countdownTicker.stop()
    }

    private func emitContentSize(label: String) {
        stackView.layoutSubtreeIfNeeded()
        let arranged = stackView.arrangedSubviews
        // Only count views that are participating in layout. The in-place
        // refactor introduced always-present detail/countdown labels that
        // get hidden when empty; their stale frame.height would otherwise
        // inflate computedHeight every refresh.
        let visible = arranged.filter { !$0.isHidden }
        let subviewHeight = visible.reduce(0) { $0 + $1.frame.height }
        let spacingTotal = max(0, CGFloat(visible.count - 1)) * stackView.spacing
        let edges = stackView.edgeInsets.top + stackView.edgeInsets.bottom
        let computedHeight = subviewHeight + spacingTotal + edges
        let fitting = stackView.fittingSize.height
        // Prefer fittingSize once layout has settled (scrollView has a real
        // width). Before that, fall back to computedHeight as a defensive
        // estimate against fittingSize under-reporting on the first pass.
        let chosen: CGFloat
        if scrollView.bounds.width > 0 {
            chosen = fitting
        } else {
            chosen = max(fitting, computedHeight)
        }
        NSLog("%@", "[ClaudeMeter] popover sizing(\(label)): fittingSize=\(fitting) computed=\(computedHeight) chosen=\(chosen) scrollW=\(scrollView.bounds.width) arranged=\(arranged.count) visible=\(visible.count)")
        onContentSizeChanged?(chosen)
    }

    func scrollToTop() {
        // Latch the request and apply it on the next data-render or runloop tick.
        // Calling it immediately after popover.show races with the resize-to-fit
        // animation triggered by onContentSizeChanged, which can leave the
        // scroll mid-content.
        pendingScrollToTop = true
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingScrollToTopIfNeeded()
        }
    }

    fileprivate func applyPendingScrollToTopIfNeeded() {
        guard pendingScrollToTop, let docView = scrollView.documentView else { return }
        pendingScrollToTop = false
        docView.scroll(NSPoint(x: 0, y: docView.bounds.height))
        scrollView.contentView.scrollToVisible(NSRect(x: 0,
                                                       y: docView.bounds.height - 1,
                                                       width: 1, height: 1))
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
        case 0..<50: return NSColor(red: 0x2b/255.0, green: 0xa8/255.0, blue: 0x82/255.0, alpha: 1)  // deep emerald
        case 50..<80: return NSColor(red: 0xc9/255.0, green: 0x9a/255.0, blue: 0x2e/255.0, alpha: 1)  // muted gold
        case 80..<95: return NSColor(red: 0xc0/255.0, green: 0x5e/255.0, blue: 0x1a/255.0, alpha: 1)  // deep amber
        default: return NSColor(red: 0xb8/255.0, green: 0x3a/255.0, blue: 0x3a/255.0, alpha: 1)       // muted crimson
        }
    }

    // MARK: - Headline support helpers

    private func forecastsEqual(_ a: UsageForecast?, _ b: UsageForecast?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?):
            // Date equality on minute granularity is fine; second-level drift
            // would otherwise rebuild the popover on every scrape.
            let etaSame: Bool
            switch (x.etaDate, y.etaDate) {
            case (nil, nil): etaSame = true
            case (let dx?, let dy?): etaSame = abs(dx.timeIntervalSince(dy)) < 60
            default: etaSame = false
            }
            // v2.7.1 — also compare ratePerHour with a small tolerance
            // (matches the .idle floor at 0.05). Without this the burn-rate
            // chip shows a stale number when state/ETA stay equal but the
            // EWMA has drifted within those equal-state bounds.
            let rateSame = abs(x.ratePerHour - y.ratePerHour) < 0.05
            return x.state == y.state && etaSame && rateSame
        default: return false
        }
    }

    // MARK: - Parked headline helpers (v2.5)
    //
    // These two helpers and HeadlineView (further down) feed the burn-rate /
    // ETA headline that v2.4 surfaced as "out at 3:31p / no recent activity".
    // The headline was parked in v2.5 because the half-populated states read
    // as debug output. Kept dormant — and called out here — so re-enabling is
    // a one-block revert in doUpdate plus restoring the two shimmer rows in
    // showLoadingSkeleton. Delete only after a clean redesign lands.
    private func sessionPercentage(in sections: [UsageSection]) -> Int? {
        for section in sections {
            for meter in section.meters where meter.label.lowercased().contains("current session") {
                return meter.percentage
            }
        }
        return nil
    }

    private func weeklyPercentageForHeadline(in sections: [UsageSection]) -> Int? {
        for section in sections where section.title.lowercased().contains("weekly") {
            for meter in section.meters {
                let l = meter.label.lowercased()
                if l == "weekly" || l == "weekly usage" || l.hasPrefix("weekly usage") {
                    return meter.percentage
                }
            }
            if let first = section.meters.first { return first.percentage }
        }
        return nil
    }
}

// MARK: - Sparkline View (v2.7)

/// Tiny inline 24h history chart rendered under the Current Session and
/// Weekly meters. Pure custom-draw so it can sit in an `NSStackView` row
/// without any layout drama. Y is percentage 0-100; X is wall time over
/// the entire history span (latest sample anchors the right edge). When
/// fewer than 3 samples are present, draws a dim guideline + "collecting…".
final class SparklineView: NSView {
    private var samples: [(t: TimeInterval, pct: Int)] = []
    private var lineColor: NSColor = .white

    init(barWidth: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: barWidth, height: 22))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        layer?.cornerRadius = 3
    }
    required init?(coder: NSCoder) { fatalError() }

    func setData(samples: [(t: TimeInterval, pct: Int)], color: NSColor) {
        self.samples = samples
        self.lineColor = color
        if let latest = samples.last, let oldest = samples.first {
            let span = latest.t - oldest.t
            let h = Int(span / 3600)
            let m = Int((span.truncatingRemainder(dividingBy: 3600)) / 60)
            let oldestPct = oldest.pct, newestPct = latest.pct
            let delta = newestPct - oldestPct
            let sign = delta >= 0 ? "+" : ""
            if span >= 60 {
                let span = h > 0 ? "\(h)h \(m)m" : "\(m)m"
                toolTip = "\(oldestPct)% \(sign)\(delta) over \(span) (last 24h)"
            } else {
                toolTip = "Collecting samples…"
            }
        } else {
            toolTip = "No history yet"
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let inset: CGFloat = 2
        let plotRect = bounds.insetBy(dx: inset, dy: inset)

        // Subtle gridlines at 50/75/90% so users have a reference for height.
        let gridColor = NSColor(white: 0.22, alpha: 1)
        gridColor.setStroke()
        for pct in [50, 75, 90] {
            let y = plotRect.minY + plotRect.height * CGFloat(pct) / 100.0
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plotRect.minX, y: y))
            path.line(to: NSPoint(x: plotRect.maxX, y: y))
            path.lineWidth = 0.5
            path.setLineDash([1, 2], count: 2, phase: 0)
            path.stroke()
        }

        // Empty / collecting state.
        if samples.count < 3 {
            let dim = NSColor(white: 0.35, alpha: 1)
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .regular),
                .foregroundColor: dim,
                .paragraphStyle: para,
            ]
            let label = "collecting…"
            let size = (label as NSString).size(withAttributes: attrs)
            let textRect = NSRect(
                x: plotRect.midX - size.width / 2,
                y: plotRect.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            (label as NSString).draw(in: textRect, withAttributes: attrs)
            return
        }

        guard let oldest = samples.first, let newest = samples.last else { return }
        let span = max(newest.t - oldest.t, 1)
        let path = NSBezierPath()
        let fill = NSBezierPath()
        for (i, s) in samples.enumerated() {
            let x = plotRect.minX + plotRect.width * CGFloat((s.t - oldest.t) / span)
            let y = plotRect.minY + plotRect.height * CGFloat(min(s.pct, 100)) / 100.0
            let p = NSPoint(x: x, y: y)
            if i == 0 {
                path.move(to: p)
                fill.move(to: NSPoint(x: x, y: plotRect.minY))
                fill.line(to: p)
            } else {
                path.line(to: p)
                fill.line(to: p)
            }
        }
        // Close the fill back along the bottom edge.
        let lastX = plotRect.minX + plotRect.width
        fill.line(to: NSPoint(x: lastX, y: plotRect.minY))
        fill.close()

        lineColor.withAlphaComponent(0.20).setFill()
        fill.fill()

        lineColor.setStroke()
        path.lineWidth = 1.25
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()

        // Latest-sample dot.
        let lx = plotRect.minX + plotRect.width
        let ly = plotRect.minY + plotRect.height * CGFloat(min(newest.pct, 100)) / 100.0
        let dot = NSBezierPath(ovalIn: NSRect(x: lx - 2.5, y: ly - 2.5, width: 5, height: 5))
        lineColor.setFill()
        dot.fill()
    }
}

// MARK: - Countdown Ticker
// 1Hz timer for live "resets in Xh Ym" countdown labels and the peak-window
// flame tooltip. Only ticks while the popover is visible (battery requirement);
// AppDelegate.togglePopover starts it and AppDelegate.popoverDidClose stops it.

final class CountdownTicker {
    private struct Entry {
        weak var label: NSTextField?
        let resetAt: Date
        let isEstimate: Bool
        let prefix: String?
    }

    private var entries: [Entry] = []
    private var flames: [Weak<NSImageView>] = []
    private var timer: Timer?

    private struct Weak<T: AnyObject> { weak var value: T? }

    func register(label: NSTextField, resetAt: Date, isEstimate: Bool, prefix: String? = nil) {
        // Idempotent: replace any existing entry for this label so callers can
        // re-bind on every refresh without tracking unregister state.
        entries.removeAll { $0.label === label }
        entries.append(Entry(label: label, resetAt: resetAt, isEstimate: isEstimate, prefix: prefix))
        // Apply once so the label gets correct text immediately, instead of
        // waiting up to 1s for the next tick (visible as a flash on first
        // render or rebind).
        apply(label: label, resetAt: resetAt, isEstimate: isEstimate, prefixOverride: prefix, now: Date())
    }

    func unregister(_ label: NSTextField) {
        entries.removeAll { $0.label === label }
    }

    func registerFlame(_ flame: NSImageView) {
        flames.append(Weak(value: flame))
    }

    func registerFlameIfMissing(_ flame: NSImageView) {
        if !flames.contains(where: { $0.value === flame }) {
            flames.append(Weak(value: flame))
        }
    }

    func clearRegistrations() {
        entries.removeAll()
        flames.removeAll()
    }

    func start() {
        timer?.invalidate()
        tick()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        var anyAlive = false
        for entry in entries {
            guard let label = entry.label else { continue }
            anyAlive = true
            apply(label: label, resetAt: entry.resetAt, isEstimate: entry.isEstimate, prefixOverride: entry.prefix, now: now)
        }
        let tooltip = AppDelegate.isInPeakWindow(now: now)
            ? UsageContentView.peakTooltipPublic(now: now)
            : nil
        for ref in flames {
            guard let flame = ref.value else { continue }
            anyAlive = true
            flame.toolTip = tooltip
        }
        // Self-prune dead refs so a long-running session doesn't accumulate.
        entries.removeAll { $0.label == nil }
        flames.removeAll { $0.value == nil }
        // Auto-stop if everything has been deallocated. Defensive only;
        // popoverDidClose is the canonical stop site.
        if !anyAlive {
            stop()
        }
    }

    private func apply(label: NSTextField, resetAt: Date, isEstimate: Bool, prefixOverride: String?, now: Date) {
        let remaining = resetAt.timeIntervalSince(now)
        let amber = NSColor(red: 0xc9/255.0, green: 0x9a/255.0, blue: 0x2e/255.0, alpha: 1)
        let dim = NSColor(white: 0.45, alpha: 1)
        // When the upstream detail already gives an absolute marker
        // ("Resets Tue 11:00 PM", "Resets Jun 1"), preserve it and append the
        // live duration: "Resets Tue 11:00 PM, in 4d 9h". Otherwise fall back
        // to the lone "resets in Xh Ym" form.
        let prefix: String
        if let p = prefixOverride, !p.isEmpty {
            prefix = "\(p), in "
        } else {
            prefix = isEstimate ? "resets in ~" : "resets in "
        }

        if remaining <= 0 {
            // Reset already passed. Stay hidden until the next scrape supplies
            // a fresh resetAt; the row was previously visible only while live.
            label.isHidden = true
            return
        }
        if remaining <= 60 {
            label.stringValue = "resetting\u{2026}"
            label.textColor = amber
            label.isHidden = false
            return
        }
        if remaining <= 600 {
            let secs = Int(remaining.rounded())
            label.stringValue = "\(prefix)\(secs)s"
            label.textColor = amber
            label.isHidden = false
            return
        }
        if remaining <= 60 * 60 {
            let mins = Int(remaining / 60)
            label.stringValue = "\(prefix)\(mins)m"
            label.textColor = dim
            label.isHidden = false
            return
        }
        if remaining > 24 * 3600 {
            let days = Int(remaining / (24 * 3600))
            let hours = (Int(remaining) % (24 * 3600)) / 3600
            label.stringValue = "\(prefix)\(days)d \(hours)h"
            label.textColor = dim
            label.isHidden = false
            return
        }
        let hours = Int(remaining / 3600)
        let mins = (Int(remaining) % 3600) / 60
        label.stringValue = "\(prefix)\(hours)h \(mins)m"
        label.textColor = dim
        label.isHidden = false
    }
}

extension UsageContentView {
    static func peakTooltipPublic(now: Date = Date()) -> String {
        let remaining = AppDelegate.peakWindowRemaining(now: now) ?? 0
        let hours = Int(remaining) / 3600
        let mins = (Int(remaining) % 3600) / 60
        return "Peak window in PT. Expect faster session burn until 11am PT (\(hours)h \(mins)m)."
    }
}

// MARK: - Headline View (burn-rate + ETA-to-limit) — PARKED in v2.5
//
// Not instantiated by the current popover (see UsageContentView.doUpdate
// where the headline branch is replaced with `_ = sessionForecast` etc.).
// Kept here so re-enabling is a single-block revert. See
// `UsageContentView.sessionPercentage(in:)` / `weeklyPercentageForHeadline`
// for the matching parked helpers, and showLoadingSkeleton for the matching
// parked shimmer rows.

private final class HeadlineView: NSStackView {
    init(sessionForecast: UsageForecast?,
         weeklyForecast: UsageForecast?,
         sessionPct: Int,
         weeklyPct: Int,
         sessionResetAt: Date?,
         weeklyResetAt: Date?) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        translatesAutoresizingMaskIntoConstraints = false

        let row1 = Self.makeRow(prefix: "out at ",
                                forecast: sessionForecast,
                                pct: sessionPct,
                                resetAt: sessionResetAt,
                                kind: .session)
        let row2 = Self.makeRow(prefix: "hits weekly cap ",
                                forecast: weeklyForecast,
                                pct: weeklyPct,
                                resetAt: weeklyResetAt,
                                kind: .weekly)
        addArrangedSubview(row1)
        addArrangedSubview(row2)
    }

    required init?(coder: NSCoder) { fatalError() }

    private enum Kind { case session, weekly }

    private static func makeRow(prefix: String,
                                forecast: UsageForecast?,
                                pct: Int,
                                resetAt: Date?,
                                kind: Kind) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 368).isActive = true

        let attributed = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
        let baseColor = NSColor.white
        let dimColor = NSColor(white: 0.55, alpha: 1)
        let redColor = NSColor(red: 0xb8/255.0, green: 0x3a/255.0, blue: 0x3a/255.0, alpha: 1)

        guard let f = forecast else {
            attributed.append(NSAttributedString(
                string: "gathering data\u{2026}",
                attributes: [.font: baseFont, .foregroundColor: dimColor]))
            let text = NSTextField(labelWithAttributedString: attributed)
            text.lineBreakMode = .byTruncatingTail
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(text)
            return row
        }

        switch f.state {
        case .insufficientData:
            attributed.append(NSAttributedString(
                string: "gathering data\u{2026}",
                attributes: [.font: baseFont, .foregroundColor: dimColor]))
        case .idle:
            attributed.append(NSAttributedString(
                string: "no recent activity",
                attributes: [.font: baseFont, .foregroundColor: dimColor]))
        case .willNotExhaust:
            attributed.append(NSAttributedString(
                string: kind == .session ? "session won\u{2019}t hit limit" : "won\u{2019}t hit weekly cap",
                attributes: [.font: baseFont, .foregroundColor: dimColor]))
        case .ok:
            attributed.append(NSAttributedString(
                string: prefix,
                attributes: [.font: baseFont, .foregroundColor: baseColor]))
            let stamp = formatETA(f.etaDate, kind: kind)
            let etaColor: NSColor
            if let eta = f.etaDate, let reset = resetAt, eta < reset {
                etaColor = redColor
            } else {
                etaColor = baseColor
            }
            attributed.append(NSAttributedString(
                string: stamp,
                attributes: [.font: baseFont, .foregroundColor: etaColor]))
        }

        let text = NSTextField(labelWithAttributedString: attributed)
        text.lineBreakMode = .byTruncatingTail
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(text)

        let pctLabel = NSTextField(labelWithString: "\(pct)%")
        pctLabel.font = .systemFont(ofSize: 11, weight: .regular)
        pctLabel.textColor = dimColor
        pctLabel.alignment = .right
        pctLabel.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(pctLabel)
        return row
    }

    private static func formatETA(_ date: Date?, kind: Kind) -> String {
        guard let date = date else { return "?" }
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale.current
        let sameDay = cal.isDate(date, inSameDayAs: Date())
        df.dateFormat = (kind == .session && sameDay) ? "h:mma" : "EEE h:mma"
        var s = df.string(from: date).lowercased()
        // Compact "3:42pm" -> "3:42p" so the headline stays scannable.
        if s.hasSuffix("am") || s.hasSuffix("pm") {
            s = String(s.dropLast())
        }
        return s
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

    // MARK: - Silent Update Check (returns version string if newer, nil otherwise)

    static func checkAvailableUpdate(completion: @escaping (String?) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard let data = data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    completion(nil)
                    return
                }
                let remote = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                completion(isNewer(remote, than: currentVersion) ? remote : nil)
            }
        }.resume()
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
