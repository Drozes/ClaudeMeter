import Foundation

/// JavaScript-based scraping logic and JSON parsing for usage data.
enum UsageScraper {
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
        } catch(e) {
            console.error('[ClaudeMeter] scrapeSessionPercentageJS error:', e);
        }
        return null;
    })()
    """

    /// JS to scrape all usage data as structured JSON from the page.
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
        } catch(e) {
            console.error('[ClaudeMeter] scrapeUsageJS error:', e);
            return '[]';
        }
    })()
    """

    /// Parse the JSON string returned by scrapeUsageJS into structured sections.
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

    /// Validates that scraped data is non-empty, logging a warning if scraping appears broken.
    static func validateScrapeResult(_ sections: [UsageSection]) -> Bool {
        if sections.isEmpty {
            NSLog("[ClaudeMeter] Scraping health check: no usage sections found. Anthropic may have changed their page layout — check for updates.")
            return false
        }
        return true
    }
}
