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
//   done                    log QA-DONE and quit

import Cocoa
import WebKit

extension AppDelegate {
    func runQATestHooks() {
        let raw = UserDefaults.standard.string(forKey: "qa.actions") ?? ""
        let actions = raw.split(separator: ",").map { String($0) }
        NSLog("%@", "QA-HOOKS actions=\(actions.count)")
        // Let launch-time work (imports, first loads, migration) settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.qaRun(actions[...])
        }
    }

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
            NSLog("%@", "QA-ACCOUNT \(i) id=\(r.id) name=\(r.displayName) label=\(r.badgeLabel) slot=\(r.badgeSlot.rawValue) primary=\(a.isPrimary) signedOut=\(a.isSignedOut) pinned=\(r.orgPinned) store=\(r.storeIdentifier == nil ? "default" : "isolated") timerNextFire=\(next)s")
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
            if let sub = item.submenu { return "\(item.title)[\(qaMenuTree(sub))]" }
            // Disabled items in account submenus show the email or org name,
            // which can contain an email address: never log them.
            if !item.isEnabled && item.action == nil && item.menu !== contextMenu { return "<info>" }
            return item.title
        }.joined(separator: " | ")
    }
}
