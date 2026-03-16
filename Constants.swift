import Foundation

/// Centralized timing constants and shared JavaScript snippets.
enum Timing {
    static let skeletonMinDisplay: TimeInterval = 0.6
    static let silentRefreshWait: TimeInterval = 1.5
    static let postLoadScrapeDelay: TimeInterval = 2.0
    static let freshnessBuffer: TimeInterval = 3.0
    static let moveToAppsDelay: TimeInterval = 1.0
    static let updateCheckDelay: TimeInterval = 30
    static let updateCheckInterval: TimeInterval = 4 * 3600
    static let quitAfterRelaunchDelay: TimeInterval = 0.5
}

/// Shared JavaScript snippets used across multiple refresh methods.
enum SharedJS {
    /// Finds and clicks the site's own refresh button on the usage page.
    /// Returns "clicked" on success, "not_found" if the button wasn't found.
    static let clickRefreshButton = """
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
}
