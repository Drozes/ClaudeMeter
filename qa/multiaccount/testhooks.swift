// QA-only test hooks for the multi-account flows. Compiled together with
// ClaudeMeter.swift ONLY by qa/multiaccount/run.sh (with
// -D CLAUDEMETER_TESTHOOKS); release builds never include this file and the
// single call site in applicationDidFinishLaunching is compiled out.
//
// Reads a comma-separated action list from the "qa.actions" default
// (pass it in the argument domain: -qa.actions "dump,wait:3,...") and runs
// the actions one after another on the main queue. Every observation is
// logged as "QA-..." lines; never logs cookies, tokens or emails.
//
// Actions:
//   wait:<seconds>          pause
//   dump                    accounts, timers, signed-out state, windows, menu
//   addSynthetic:<name>     add an account with no sign-in (fresh empty store)
//   addThenCancel:<name>    start Add Account, open its login window, close it
//   signIn:<index>          open that account's login window (user action)
//   closeLogin:<index>      close that account's login window
//   rename:<index>:<name>   rename through the controller
//   seedKeys:<index>        write one synthetic key per per-account family
//   keys:<index>            count that account's namespaced keys
//   remove:<index>          remove through AppDelegate.removeAccount
//   badge                   log the status-item title
//   setSlot:<index>:<slot>  left | right | hidden (moves an occupant to hidden)
//   setLabel:<index>:<txt>  badge label
//   inject:<index>:<pct>    feed synthetic sections (session pct, weekly 30%)
//   signOut:<index>         mark the account signed out
//   openPopover / closePopover
//   popover                 log popover mode, sections and heights
//   makeOrphanStore         create an isolated store no account references
//   sweep                   run the orphaned-store sweep now
//   forecast:<index>:<rate|idle>  set the session forecast (burn rate) and
//                           refresh the badge
//   dot:on|off              Show Activity Dot toggle
//   setColor:<index>:<key>  account colour (palette key)
//   shot:<name>             log the badge's screen rect (run.sh captures the
//                           real menu bar) and write <name>-light.png /
//                           <name>-dark.png renders of the button into the
//                           directory given by -qa.shotDir
//   injectWeekly:<index>:<pct>    feed a weekly-only fetch (no session window)
//   forecastWeekly:<index>:<rate|idle>  set the weekly forecast
//   renderPopover:<name>    render account 0's usage view to <name>-popover.png
//   sleep / wake            post NSWorkspace willSleep / didWake
//   counters                per account: fetch attempts, JSON successes, page
//                           loads, page scripts, cookie write-backs, parked
//   cookies:<index>         cookie count in that account's own store
//   circuit:<index>:open    open that account's JSON circuit now (DOM path)
//   circuit:<index>:expire  age the open circuit past its cooldown, so the
//                           next timer tick resets it
//   screensSleep / screensWake  post NSWorkspace screensDidSleep / DidWake
//   postLock / postUnlock   post the QA alias of com.apple.screenIsLocked /
//                           Unlocked as a distributed notification while
//                           this app's distributed notifications are
//                           suspended (as for an inactive app), without
//                           deliverImmediately (as the system posts it)
//   pauseInfo               log the pause reasons
//   agePause:<reason>:<h>   backdate a pause reason by <h> hours
//   reconcile               run the paused-state safety check now
//   done                    log QA-DONE and quit

import Cocoa
import WebKit

extension AppDelegate {
    func runQATestHooks() {
        let raw = UserDefaults.standard.string(forKey: "qa.actions") ?? ""
        let actions = raw.split(separator: ",").map { String($0) }
        NSLog("%@", "QA-HOOKS actions=\(actions.count)")
        // Same observer path as the real lock notifications, under QA-only
        // names (posting the real ones would reach every app).
        observeLockNotifications(lock: Self.qaLockName, unlock: Self.qaUnlockName)
        // Let launch-time work (imports, first loads, migration) settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.qaRun(actions[...])
        }
    }

    static let qaLockName = "com.local.ClaudeMeter.qa.screenIsLocked"
    static let qaUnlockName = "com.local.ClaudeMeter.qa.screenIsUnlocked"

    private func qaRun(_ actions: ArraySlice<String>) {
        guard let action = actions.first else { return }
        let rest = actions.dropFirst()
        let parts = action.split(separator: ":", maxSplits: 2).map { String($0) }
        var delay: TimeInterval = 0.5
        NSLog("%@", "QA-ACTION \(action)")
        switch parts[0] {
        case "wait":
            delay = TimeInterval(parts.count > 1 ? parts[1] : "1") ?? 1
        case "dump":
            qaDump()
        case "addSynthetic":
            if #available(macOS 14.0, *) {
                let c = beginAddAccount(named: parts.count > 1 ? parts[1] : "Synthetic")
                c.onLoginWindowClosed = nil
                pendingAccounts.removeAll { $0 === c }
                finishAddAccount(c)
                c.start()
            }
        case "addThenCancel":
            if #available(macOS 14.0, *) {
                let c = beginAddAccount(named: parts.count > 1 ? parts[1] : "Cancelled")
                c.showLoginWindow()
                NSLog("%@", "QA-PENDING id=\(c.id) pending=\(pendingAccounts.count) accounts=\(accounts.count)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { c.closeLoginWindow() }
                delay = 4.0
            }
        case "signIn":
            qaAccount(parts)?.showLoginWindow()
        case "closeLogin":
            qaAccount(parts)?.closeLoginWindow()
        case "rename":
            if let a = qaAccount(parts), parts.count > 2 { a.rename(to: parts[2]) }
        case "seedKeys":
            if let a = qaAccount(parts) {
                let d = UserDefaults.standard
                let ts = Int(Date().timeIntervalSince1970)
                for family in AccountStore.perAccountKeyFamilies {
                    d.set(1, forKey: AccountKeys.key(family, a.id, "qa.\(ts)"))
                }
                d.set(1, forKey: AccountKeys.key(AppDelegate.lastFetchPathKey, a.id))
            }
        case "keys":
            if let a = qaAccount(parts) {
                NSLog("%@", "QA-KEYS index=\(parts[1]) id=\(a.id) count=\(qaKeyCount(a.id))")
            }
        case "remove":
            if let a = qaAccount(parts) {
                let id = a.id
                let historyURL = UsageHistory.fileURL(accountID: id)
                try? "{\"version\":1,\"samples\":[]}".write(to: historyURL, atomically: true, encoding: .utf8)
                removeAccount(a)
                let stillSaved = AccountStore.load().contains { $0.id == id }
                NSLog("%@", "QA-REMOVED id=\(id) keysLeft=\(qaKeyCount(id)) recordLeft=\(stillSaved) historyLeft=\(FileManager.default.fileExists(atPath: historyURL.path))")
            }
        case "badge":
            let style = appliedBadgeStyle
            let dots = style?.dots.map { $0.band.rawValue } ?? []
            let tints = style?.tints.map { $0.color.rawValue } ?? []
            // Label tint really present in the attributed title?
            var tintOK = true
            if let button = statusItem.button, let style = style {
                let attributed = button.attributedTitle
                for tint in style.tints {
                    let color = attributed.attribute(.foregroundColor, at: tint.range.location, effectiveRange: nil) as? NSColor
                    if color != tint.color.color { tintOK = false }
                }
            }
            NSLog("%@", "QA-BADGE title='\(statusItem.button?.title ?? "")'")
            NSLog("%@", "QA-BADGESTYLE attributed=\(style != nil) dots=\(dots) dotViews=\(badgeDotViews.count) tints=\(tints) tintOK=\(tintOK)")
            NSLog("%@", "QA-BADGEA11Y '\(statusItem.button?.accessibilityValue() as? String ?? "")'")
            NSLog("%@", "QA-TOOLTIP '\((statusItem.button?.toolTip ?? "").replacingOccurrences(of: "\n", with: " / "))'")
        case "setSlot":
            if let a = qaAccount(parts), parts.count > 2 {
                let slot: BadgeSlot = parts[2] == "left" ? .left : (parts[2] == "right" ? .right : .hidden)
                setBadgeSlot(slot, for: a)
            }
        case "setLabel":
            if let a = qaAccount(parts), parts.count > 2 { setBadgeLabel(parts[2], for: a) }
        case "inject":
            if let a = qaAccount(parts), parts.count > 2, let pct = Int(parts[2]) {
                a.distributeFetchResult([
                    UsageSection(title: "Session limit", meters: [UsageMeter(label: "Current session", percentage: pct, detail: "")]),
                    UsageSection(title: "Weekly limit", meters: [UsageMeter(label: "Weekly usage", percentage: 30, detail: "")]),
                ], path: "json")
            }
        case "signOut":
            qaAccount(parts)?.setSignedOut(true, reason: "qa")
        case "openPopover":
            // A background test app loses focus at once, which closes a
            // transient popover; keep it open until closePopover.
            popover.behavior = .applicationDefined
            if popover?.isShown != true { togglePopover() }
            delay = 2.0
        case "closePopover":
            if popover?.isShown == true { popover.performClose(nil) }
            popover.behavior = .transient
        case "popover":
            let vc = popover?.contentViewController
            if let multi = multiAccountView, vc?.view === multi {
                let states = multi.sectionStates.map { "\($0.showsUsage ? "usage" : "signedOut"):\(Int($0.usageHeight))" }
                let headers = multi.headerColors.map { c in AccountColor.allCases.first { $0.color == c }?.rawValue ?? "?" }
                NSLog("%@", "QA-POPOVER mode=multi sections=\(states.count) [\(states.joined(separator: ","))] total=\(Int(multi.contentHeight)) contentSize=\(Int(popover.contentSize.height)) shown=\(popover.isShown) headers=\(headers)")
            } else {
                NSLog("%@", "QA-POPOVER mode=single usageViewIsContent=\(vc?.view === usageView) contentSize=\(Int(popover?.contentSize.height ?? 0))")
            }
        case "makeOrphanStore":
            if #available(macOS 14.0, *) {
                let id = UUID()
                let config = WKWebViewConfiguration()
                config.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
                var webView: WKWebView? = WKWebView(frame: .zero, configuration: config)
                webView?.loadHTMLString("<p>qa</p>", baseURL: URL(string: "https://example.invalid/"))
                NSLog("%@", "QA-ORPHAN id=\(id)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { webView = nil }
            }
        case "sweep":
            sweepOrphanedDataStores()
        case "injectWeekly", "injectWeeklyDOM":
            // A weekly-only fetch through the JSON path (authoritative) or
            // the DOM path (XPath session scrape first).
            if let a = qaAccount(parts), parts.count > 2, let pct = Int(parts[2]) {
                a.distributeFetchResult([
                    UsageSection(title: "Weekly limit", meters: [
                        UsageMeter(label: "Weekly usage", percentage: pct, detail: ""),
                        UsageMeter(label: "Weekly Sonnet usage", percentage: 3, detail: ""),
                    ]),
                ], path: parts[0] == "injectWeeklyDOM" ? "dom" : "json")
            }
            delay = 1.5
        case "waitSignedOut":
            // Poll (0.5s) until the account is signed out, at most N seconds:
            // robust against slow page loads and API answers under load.
            if let a = qaAccount(parts) {
                let limit = Date().addingTimeInterval(TimeInterval(parts.count > 2 ? parts[2] : "45") ?? 45)
                qaPoll(until: { a.isSignedOut }, deadline: limit, label: action) { [weak self] in
                    self?.qaRun(rest)
                }
                return
            }
        case "forecastWeekly":
            if let a = qaAccount(parts), parts.count > 2 {
                if parts[2] == "idle" {
                    a.lastWeeklyForecast = UsageForecast(ratePerHour: 0, etaDate: nil, state: .idle)
                } else if let rate = Double(parts[2]) {
                    a.lastWeeklyForecast = UsageForecast(ratePerHour: rate, etaDate: nil, state: .ok)
                }
                updateBadgeFromModel()
            }
        case "renderPopover":
            if let view = usageView, let dir = UserDefaults.standard.string(forKey: "qa.shotDir") {
                let name = parts.count > 1 ? parts[1] : "popover"
                view.frame = NSRect(x: 0, y: 0, width: 400, height: max(view.skeletonHeight, 120))
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-popover.png"))
                }
                NSLog("%@", "QA-POPOVERVIEW \(name) height=\(Int(view.skeletonHeight))")
            }
            delay = 2.0
        case "forecast":
            if let a = qaAccount(parts), parts.count > 2 {
                if parts[2] == "idle" {
                    a.lastSessionForecast = UsageForecast(ratePerHour: 0, etaDate: nil, state: .idle)
                } else if let rate = Double(parts[2]) {
                    a.lastSessionForecast = UsageForecast(ratePerHour: rate, etaDate: nil, state: .ok)
                }
                updateBadgeFromModel()
            }
        case "dot":
            showActivityDot = parts.count > 1 && parts[1] == "on"
        case "setColor":
            if let a = qaAccount(parts), parts.count > 2 {
                a.updateRecord { $0.colorKey = parts[2] }
            }
        case "shot":
            let name = parts.count > 1 ? parts[1] : "shot"
            qaShot(name)
            delay = 3.0
        case "tiers":
            // Plan-tier labels for representative inputs (no live data).
            let cases: [(String?, String?)] = [
                ("default_claude_max_20x", nil), ("default_raven", nil), ("default_raven", "team"),
                ("default_raven", "enterprise"), ("default_claude_max_50x", nil), ("default_foo_bar", nil),
                ("default_", nil), (nil, nil),
            ]
            for (slug, variant) in cases {
                NSLog("%@", "QA-TIER \(slug ?? "nil")/\(variant ?? "nil") -> \(AppDelegate.planTierDisplayName(slug: slug, variant: variant) ?? "nil")")
            }
        case "sleep":
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        case "wake":
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        case "counters":
            for (i, a) in accounts.enumerated() {
                NSLog("%@", "QA-COUNTERS \(i) attempts=\(a.fetchAttemptCount) json=\(a.jsonSuccessCount) pageLoads=\(a.pageLoadCount) pageScripts=\(a.pageScriptCount) cookieWriteBacks=\(a.cookieWriteBackCount) parked=\(a.pageView == nil) timer=\(a.refreshTimer != nil) paused=\(activityPaused) circuit=\(a.jsonCircuitOpen ? "open" : "closed") loginShows=\(a.loginWindowShowCount) loginWindow=\(a.loginWindow != nil) signedOut=\(a.isSignedOut)")
            }
        case "cookies":
            if let a = qaAccount(parts) {
                let index = parts[1]
                a.dataStore.httpCookieStore.getAllCookies { cookies in
                    NSLog("%@", "QA-COOKIES \(index) store=\(cookies.count) writeBacks=\(a.cookieWriteBackCount)")
                }
                delay = 1.0
            }
        case "circuit":
            if let a = qaAccount(parts), parts.count > 2 {
                if parts[2] == "open" {
                    a.jsonCircuitOpen = true
                    a.jsonCircuitOpenedAt = Date()
                    a.jsonConsecutiveFailures = AccountController.jsonFailureCircuitBreaker
                } else if parts[2] == "expire" {
                    a.jsonCircuitOpenedAt = Date().addingTimeInterval(-AccountController.jsonCircuitResetInterval - 1)
                }
                NSLog("%@", "QA-CIRCUIT \(parts[1]) \(a.jsonCircuitOpen ? "open" : "closed")")
            }
        case "screensSleep":
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        case "screensWake":
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        case "postLock", "postUnlock":
            let dnc = DistributedNotificationCenter.default()
            dnc.suspended = true
            dnc.postNotificationName(Notification.Name(parts[0] == "postLock" ? Self.qaLockName : Self.qaUnlockName),
                                     object: nil, userInfo: nil, deliverImmediately: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                NSLog("%@", "QA-LOCKPOST \(parts[0]) paused=\(self.activityPaused) reasons=\(self.pauseReasons.keys.sorted())")
                dnc.suspended = false
            }
            delay = 2.5
        case "pauseInfo":
            NSLog("%@", "QA-PAUSE paused=\(activityPaused) reasons=\(pauseReasons.keys.sorted())")
        case "agePause":
            if parts.count > 2, let h = Double(parts[2]), pauseReasons[parts[1]] != nil {
                pauseReasons[parts[1]] = Date().addingTimeInterval(-h * 3600)
            }
            NSLog("%@", "QA-PAUSE paused=\(activityPaused) reasons=\(pauseReasons.keys.sorted())")
        case "reconcile":
            reconcilePauseReasons()
        case "done":
            NSLog("%@", "QA-DONE")
            NSApp.terminate(nil)
            return
        default:
            NSLog("%@", "QA-UNKNOWN \(action)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.qaRun(rest)
        }
    }

    /// Logs the badge's screen rect (top-left origin, points) for run.sh's
    /// screencapture, and renders the button under forced light and dark
    /// appearance over menu-bar-like backgrounds.
    private func qaShot(_ name: String) {
        guard let button = statusItem.button, let window = button.window else { return }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let top = screenHeight - frame.maxY
        NSLog("%@", "QA-SHOT \(name) \(Int(frame.minX)) \(Int(top)) \(Int(frame.width)) \(Int(frame.height))")
        guard let dir = UserDefaults.standard.string(forKey: "qa.shotDir") else { return }
        let variants: [(String, NSAppearance.Name?, NSColor)] = [
            ("light", .aqua, NSColor(white: 0.93, alpha: 1)),
            ("dark", .darkAqua, NSColor(white: 0.16, alpha: 1)),
            ("current", nil, NSColor(white: 0.55, alpha: 1)),   // the menu bar's own appearance
        ]
        for (suffix, appearanceName, background) in variants {
            let saved = button.appearance
            if let appearanceName = appearanceName { button.appearance = NSAppearance(named: appearanceName) }
            button.needsDisplay = true
            button.subviews.forEach { $0.needsDisplay = true }
            guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { continue }
            button.cacheDisplay(in: button.bounds, to: rep)
            button.appearance = saved
            let size = NSSize(width: button.bounds.width * 3, height: button.bounds.height * 3)
            let out = NSImage(size: size)
            out.lockFocus()
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
            rep.draw(in: NSRect(origin: .zero, size: size))
            out.unlockFocus()
            if let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
               let png = bmp.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
    }

    private func qaPoll(until condition: @escaping () -> Bool, deadline: Date, label: String,
                        then next: @escaping () -> Void) {
        if condition() || Date() >= deadline {
            NSLog("%@", "QA-WAIT \(label) met=\(condition())")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.qaPoll(until: condition, deadline: deadline, label: label, then: next)
        }
    }

    private func qaAccount(_ parts: [String]) -> AccountController? {
        guard parts.count > 1, let i = Int(parts[1]), accounts.indices.contains(i) else {
            NSLog("%@", "QA-NOACCOUNT \(parts)")
            return nil
        }
        return accounts[i]
    }

    private func qaKeyCount(_ id: String) -> Int {
        UserDefaults.standard.dictionaryRepresentation().keys.filter { key in
            AccountStore.perAccountKeyFamilies.contains { key == "\($0).\(id)" || key.hasPrefix("\($0).\(id).") }
        }.count
    }

    private func qaDump() {
        let now = Date()
        NSLog("%@", "QA-STATE accounts=\(accounts.count) pending=\(pendingAccounts.count) saved=\(AccountStore.load().count) canAdd=\(canAddAccounts)")
        for (i, a) in accounts.enumerated() {
            let r = a.record
            let next = a.refreshTimer.map { String(format: "%.0f", $0.fireDate.timeIntervalSince(now)) } ?? "none"
            NSLog("%@", "QA-ACCOUNT \(i) id=\(r.id) name=\(r.displayName) label=\(r.badgeLabel) slot=\(r.badgeSlot.rawValue) primary=\(a.isPrimary) signedOut=\(a.isSignedOut) pinned=\(r.orgPinned) store=\(r.storeIdentifier == nil ? "default" : "isolated") color=\(accountColor(for: a).rawValue) colorKey=\(r.colorKey ?? "nil") cachedBadge=\(UserDefaults.standard.object(forKey: a.lastBadgePercentageKey).map { "\($0)" } ?? "nil") weeklyOnly=\(a.weeklyOnlyConfirmed) showsWeekly=\(a.badgeShowsWeekly) timerNextFire=\(next)s")
        }
        // Titled, visible app windows (the status item's own window excluded).
        let windows = NSApp.windows.filter {
            $0.isVisible && !$0.title.isEmpty && !String(describing: type(of: $0)).contains("StatusBar")
        }.map { $0.title }
        NSLog("%@", "QA-WINDOWS visible=\(windows)")
        if let menu = contextMenu {
            NSLog("%@", "QA-MENU \(qaMenuTree(menu))")
        }
    }

    private func qaMenuTree(_ menu: NSMenu) -> String {
        menu.items.filter { !$0.isSeparatorItem }.map { item in
            // Redact the org/email line first, whatever markers it would get.
            if item.tag == AppDelegate.accountInfoMenuTag { return "<info>" }
            let img = (item.image != nil ? "{img}" : "") + (item.isHidden ? "{hidden}" : "")
            let on = item.state == .on ? "{on}" : ""
            if let sub = item.submenu { return "\(item.title)\(img)[\(qaMenuTree(sub))]" }
            if !img.isEmpty || !on.isEmpty { return "\(item.title)\(img)\(on)" }
            // Disabled items in account submenus show the email or org name,
            // which can contain an email address: never log them.
            return item.title
        }.joined(separator: " | ")
    }
}
