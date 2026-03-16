// ClaudeMeterTests.swift – lightweight unit tests for pure logic.
// Compiled separately from the app (excluding ClaudeMeter.swift to avoid @main conflict).
// Run via:  swiftc Constants.swift UsageModels.swift UsageScraper.swift UsageContentView.swift \
//             AppUpdater.swift ClaudeDesktopCookies.swift ClaudeMeterTests.swift \
//             -framework Cocoa -framework WebKit -framework Security \
//             -lsqlite3 -parse-as-library -o ClaudeMeterTests && ./ClaudeMeterTests

import Foundation

// ---------------------------------------------------------------------------
// MARK: - Helpers
// ---------------------------------------------------------------------------

private var passCount = 0
private var failCount = 0

private func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "",
                                        file: String = #file, line: Int = #line) {
    if a == b {
        passCount += 1
    } else {
        failCount += 1
        print("  FAIL (\(file):\(line)): \(msg.isEmpty ? "" : msg + " – ")expected \(b), got \(a)")
    }
}

private func assertTrue(_ condition: Bool, _ msg: String = "",
                         file: String = #file, line: Int = #line) {
    if condition {
        passCount += 1
    } else {
        failCount += 1
        print("  FAIL (\(file):\(line)): \(msg.isEmpty ? "" : msg + " – ")expected true")
    }
}

private func assertFalse(_ condition: Bool, _ msg: String = "",
                          file: String = #file, line: Int = #line) {
    assertTrue(!condition, msg, file: file, line: line)
}

// ---------------------------------------------------------------------------
// MARK: - UsageScraper.parseUsageJSON tests
// ---------------------------------------------------------------------------

func testParseUsageJSON_validData() {
    print("  testParseUsageJSON_validData")

    let json = """
    [
        {"section":"Models","label":"Opus","percentage":42,"detail":"42 % used"},
        {"section":"Models","label":"Sonnet","percentage":10,"detail":"10 % used"},
        {"section":"Features","label":"Code","percentage":80,"detail":"80 % used"}
    ]
    """

    let sections = UsageScraper.parseUsageJSON(json)

    assertEqual(sections.count, 2, "should have 2 sections")
    assertEqual(sections[0].title, "Models", "first section title")
    assertEqual(sections[0].meters.count, 2, "Models meter count")
    assertEqual(sections[0].meters[0].label, "Opus", "first meter label")
    assertEqual(sections[0].meters[0].percentage, 42, "first meter percentage")
    assertEqual(sections[0].meters[0].detail, "42 % used", "first meter detail")
    assertEqual(sections[0].meters[1].label, "Sonnet", "second meter label")
    assertEqual(sections[1].title, "Features", "second section title")
    assertEqual(sections[1].meters.count, 1, "Features meter count")
    assertEqual(sections[1].meters[0].label, "Code", "Features meter label")
    assertEqual(sections[1].meters[0].percentage, 80, "Features meter percentage")
}

func testParseUsageJSON_emptyArray() {
    print("  testParseUsageJSON_emptyArray")

    let sections = UsageScraper.parseUsageJSON("[]")
    assertEqual(sections.count, 0, "empty array should produce no sections")
}

func testParseUsageJSON_invalidJSON() {
    print("  testParseUsageJSON_invalidJSON")

    let sections = UsageScraper.parseUsageJSON("this is not json")
    assertEqual(sections.count, 0, "invalid JSON should produce no sections")
}

func testParseUsageJSON_missingFields() {
    print("  testParseUsageJSON_missingFields")

    let json = """
    [
        {"section":"S1"},
        {"label":"L2","percentage":55}
    ]
    """
    let sections = UsageScraper.parseUsageJSON(json)
    assertEqual(sections.count, 2, "should produce 2 sections (S1 and default empty)")

    let s1 = sections[0]
    assertEqual(s1.title, "S1", "first section title")
    assertEqual(s1.meters[0].label, "", "default label is empty string")
    assertEqual(s1.meters[0].percentage, 0, "default percentage is 0")
    assertEqual(s1.meters[0].detail, "", "default detail is empty string")

    let s2 = sections[1]
    assertEqual(s2.title, "", "second section title is empty default")
    assertEqual(s2.meters[0].label, "L2", "provided label")
    assertEqual(s2.meters[0].percentage, 55, "provided percentage")
    assertEqual(s2.meters[0].detail, "", "default detail")
}

func testParseUsageJSON_sectionOrdering() {
    print("  testParseUsageJSON_sectionOrdering")

    let json = """
    [
        {"section":"Zebra","label":"Z1","percentage":1,"detail":""},
        {"section":"Alpha","label":"A1","percentage":2,"detail":""},
        {"section":"Middle","label":"M1","percentage":3,"detail":""}
    ]
    """
    let sections = UsageScraper.parseUsageJSON(json)
    assertEqual(sections.count, 3, "should have 3 sections")
    assertEqual(sections[0].title, "Zebra", "order follows JSON, not alphabetical")
    assertEqual(sections[1].title, "Alpha")
    assertEqual(sections[2].title, "Middle")
}

// ---------------------------------------------------------------------------
// MARK: - UsageScraper.validateScrapeResult tests
// ---------------------------------------------------------------------------

func testValidateScrapeResult_empty() {
    print("  testValidateScrapeResult_empty")

    let sections: [UsageSection] = []
    assertFalse(UsageScraper.validateScrapeResult(sections), "empty sections should fail validation")
}

func testValidateScrapeResult_nonEmpty() {
    print("  testValidateScrapeResult_nonEmpty")

    let sections = [UsageSection(title: "T", meters: [UsageMeter(label: "L", percentage: 50, detail: "d")])]
    assertTrue(UsageScraper.validateScrapeResult(sections), "non-empty sections should pass validation")
}

// ---------------------------------------------------------------------------
// MARK: - AppUpdater.isNewer tests
// ---------------------------------------------------------------------------

func testIsNewer() {
    print("  testIsNewer")

    assertTrue(AppUpdater.isNewer("1.8", than: "1.7"), "1.8 > 1.7")
    assertFalse(AppUpdater.isNewer("1.7", than: "1.7"), "1.7 == 1.7")
    assertTrue(AppUpdater.isNewer("2.0", than: "1.9"), "2.0 > 1.9")
    assertTrue(AppUpdater.isNewer("1.7.1", than: "1.7"), "1.7.1 > 1.7")
    assertFalse(AppUpdater.isNewer("1.7", than: "1.8"), "1.7 < 1.8")
}

// ---------------------------------------------------------------------------
// MARK: - Timing constants tests
// ---------------------------------------------------------------------------

func testTimingConstants() {
    print("  testTimingConstants")

    assertTrue(Timing.skeletonMinDisplay > 0, "skeletonMinDisplay should be positive")
    assertEqual(Timing.skeletonMinDisplay, 0.6, "skeletonMinDisplay")
    assertEqual(Timing.silentRefreshWait, 1.5, "silentRefreshWait")
    assertEqual(Timing.postLoadScrapeDelay, 2.0, "postLoadScrapeDelay")
    assertEqual(Timing.freshnessBuffer, 3.0, "freshnessBuffer")
}

// ---------------------------------------------------------------------------
// MARK: - SharedJS tests
// ---------------------------------------------------------------------------

func testSharedJS() {
    print("  testSharedJS")

    assertFalse(SharedJS.clickRefreshButton.isEmpty, "clickRefreshButton JS should not be empty")
    assertTrue(SharedJS.clickRefreshButton.contains("clicked"), "should return 'clicked' on success")
    assertTrue(SharedJS.clickRefreshButton.contains("not_found"), "should return 'not_found' on failure")
}

// ---------------------------------------------------------------------------
// MARK: - Model struct equality tests
// ---------------------------------------------------------------------------

func testUsageMeterEquality() {
    print("  testUsageMeterEquality")

    let a = UsageMeter(label: "X", percentage: 10, detail: "d")
    let b = UsageMeter(label: "X", percentage: 10, detail: "d")
    let c = UsageMeter(label: "Y", percentage: 10, detail: "d")
    assertTrue(a == b, "identical meters should be equal")
    assertFalse(a == c, "different meters should not be equal")
}

func testUsageSectionEquality() {
    print("  testUsageSectionEquality")

    let m = UsageMeter(label: "L", percentage: 50, detail: "d")
    let s1 = UsageSection(title: "T", meters: [m])
    let s2 = UsageSection(title: "T", meters: [m])
    let s3 = UsageSection(title: "Other", meters: [m])
    assertTrue(s1 == s2, "identical sections should be equal")
    assertFalse(s1 == s3, "different sections should not be equal")
}

// ---------------------------------------------------------------------------
// MARK: - Test Runner
// ---------------------------------------------------------------------------

@main
struct TestRunner {
    static func main() {
        print("Running ClaudeMeter tests...\n")

        // parseUsageJSON
        testParseUsageJSON_validData()
        testParseUsageJSON_emptyArray()
        testParseUsageJSON_invalidJSON()
        testParseUsageJSON_missingFields()
        testParseUsageJSON_sectionOrdering()

        // validateScrapeResult
        testValidateScrapeResult_empty()
        testValidateScrapeResult_nonEmpty()

        // AppUpdater.isNewer
        testIsNewer()

        // Timing constants
        testTimingConstants()

        // SharedJS
        testSharedJS()

        // Model equality
        testUsageMeterEquality()
        testUsageSectionEquality()

        print("")
        if failCount > 0 {
            print("\(failCount) FAILED, \(passCount) passed.")
            exit(1)
        } else {
            print("All \(passCount) assertions passed.")
        }
    }
}
