// L2 — DOM contract validator.
//
// Extracts the JS scrapers from ClaudeMeter.swift at runtime so the validator
// always tests the code that ships, then runs them against a fixture HTML in
// jsdom and compares to the expected JSON.
//
// Usage:
//   node qa/check-selectors.mjs              # uses qa/fixtures/synthetic.{html,expected.json}
//   node qa/check-selectors.mjs current      # uses qa/fixtures/current.{html,expected.json}
//   node qa/check-selectors.mjs json         # validates UsageAPIResponse normalization
//                                              against qa/fixtures/usage-api.sample.json
//                                              + usage-api.expected.json
//
// Exits 0 on PASS, 1 on FAIL. Prints a structured report to stderr.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..");
const SRC = path.join(repo, "ClaudeMeter.swift");

const fixtureName = process.argv[2] || "synthetic";

const log = (msg) => process.stderr.write(`[L2] ${msg}\n`);

function fail(reasons) {
    log("FAIL");
    for (const r of reasons) log(`  - ${r}`);
    process.exit(1);
}

// ---- 0. JSON path branch ---------------------------------------------------
// When invoked with `json`, validate the UsageAPIResponse normalization
// (see normalizeJSONResponse in ClaudeMeter.swift) against a sample API
// response. This protects the JSON-primary fetch path from silent regressions
// when the undocumented endpoint shifts shape.

if (fixtureName === "json") {
    // Every qa/fixtures/usage-api*.sample.json with a matching
    // *.expected.json is checked (current schema and legacy keys).
    const dir = path.join(here, "fixtures");
    const samples = fs.readdirSync(dir).filter((f) => /^usage-api.*\.sample\.json$/.test(f)).sort();
    if (!samples.length) fail([`no usage-api*.sample.json fixtures in ${dir}`]);

    // Mirror Swift normalizeJSONResponse. Keep behavior in lockstep with the
    // Swift implementation so this validator catches normalization drift.
    // utilization is a percentage (0-100) since v2.6.1; no fraction scaling.
    const pct = (w) => {
        if (typeof w.percent_used === "number") return w.percent_used;
        if (typeof w.utilization === "number") return Math.round(w.utilization);
        return 0;
    };
    const detail = (w) => (w.resets_at ? `Resets ${w.resets_at}` : "");
    const normalize = (r) => {
        const session = [];
        const weekly = [];
        // `??` like Swift's optional fallback: only null/undefined fall back
        // (an empty-string label stays empty, as in Swift).
        const s = r.five_hour ?? r.session;
        if (s) session.push({ label: s.label ?? "Current session", percentage: pct(s), detail: detail(s) });
        const w = r.seven_day ?? r.weekly;
        if (w) weekly.push({ label: w.label ?? "Weekly usage", percentage: pct(w), detail: detail(w) });
        for (const [model, win] of [["Opus", r.seven_day_opus], ["Sonnet", r.seven_day_sonnet]]) {
            if (win) weekly.push({ label: `Weekly ${model} usage`, percentage: pct(win), detail: detail(win) });
        }
        if (Array.isArray(r.per_model)) {
            for (const pm of r.per_model) {
                const model = pm.model ?? "";
                const baseLabel = pm.label ?? (model ? `Weekly ${model} usage` : "Weekly");
                weekly.push({ label: baseLabel, percentage: pct(pm), detail: detail(pm) });
            }
        }
        const sections = [];
        if (session.length) sections.push({ title: "Session limit", meters: session });
        if (weekly.length) sections.push({ title: "Weekly limit", meters: weekly });
        return sections;
    };
    // Mirror AccountController.badgeReading: the session window when the
    // fetch has one, else (plans without a session limit) the weekly window.
    const badgeChoice = (sections) => {
        for (const sec of sections) {
            for (const m of sec.meters) {
                if (m.label.toLowerCase().includes("current session")) return { source: "session", percentage: m.percentage };
            }
        }
        for (const sec of sections.filter((x) => x.title.toLowerCase().includes("weekly"))) {
            const hit = sec.meters.find((m) => {
                const l = m.label.toLowerCase();
                return l === "weekly" || l === "weekly usage" || l.startsWith("weekly usage");
            });
            if (hit) return { source: "weekly", percentage: hit.percentage };
            if (sec.meters.length) return { source: "weekly", percentage: sec.meters[0].percentage };
        }
        return null;
    };

    let failures = [];
    for (const sampleName of samples) {
        const base = sampleName.replace(/\.sample\.json$/, "");
        const expectedPath = path.join(dir, `${base}.expected.json`);
        if (!fs.existsSync(expectedPath)) { failures.push(`${base}: missing ${base}.expected.json`); continue; }
        const sample = JSON.parse(fs.readFileSync(path.join(dir, sampleName), "utf8"));
        const expectedJson = JSON.parse(fs.readFileSync(expectedPath, "utf8"));
        const sections = normalize(sample);
        const meters = sections.flatMap((x) => x.meters);
        const reasons = [];
        const u = expectedJson.normalizeJSONResponse || {};
        if (typeof u.minMeters === "number" && meters.length < u.minMeters) {
            reasons.push(`normalizeJSONResponse: expected >=${u.minMeters} meters, got ${meters.length}`);
        }
        const lower = meters.map((m) => String(m.label || "").toLowerCase());
        for (const needle of u.requireLabels || []) {
            if (!lower.some((l) => l.includes(needle.toLowerCase()))) {
                reasons.push(`normalizeJSONResponse: no meter label contains "${needle}" (got: ${JSON.stringify(meters.map((m) => m.label))})`);
            }
        }
        for (const needle of u.forbidLabels || []) {
            if (lower.some((l) => l.includes(needle.toLowerCase()))) {
                reasons.push(`normalizeJSONResponse: unexpected meter label containing "${needle}"`);
            }
        }
        if (Array.isArray(u.requireSectionTitles)) {
            const titles = sections.map((x) => x.title);
            if (JSON.stringify(titles) !== JSON.stringify(u.requireSectionTitles)) {
                reasons.push(`normalizeJSONResponse: sections ${JSON.stringify(titles)}, expected ${JSON.stringify(u.requireSectionTitles)}`);
            }
        }
        const got = new Set(meters.map((m) => m.percentage));
        for (const p of u.requirePercentages || []) {
            if (!got.has(p)) reasons.push(`normalizeJSONResponse: missing percentage ${p}`);
        }
        const f = expectedJson.sessionPercentageFromModel || {};
        if (typeof f.expected === "number") {
            const needle = String(f.matchLabelContains || "current session").toLowerCase();
            const hit = meters.find((m) => String(m.label || "").toLowerCase().includes(needle));
            if (!hit) reasons.push(`sessionPercentageFromModel: no meter label contains "${needle}"`);
            else if (hit.percentage !== f.expected) reasons.push(`sessionPercentageFromModel: expected ${f.expected}, got ${hit.percentage}`);
        }
        if (expectedJson.badgeChoice) {
            const choice = badgeChoice(sections);
            if (JSON.stringify(choice) !== JSON.stringify(expectedJson.badgeChoice)) {
                reasons.push(`badgeChoice: expected ${JSON.stringify(expectedJson.badgeChoice)}, got ${JSON.stringify(choice)}`);
            }
        }
        if (reasons.length) {
            failures = failures.concat(reasons.map((r) => `${base}: ${r}`));
        } else {
            log(`PASS fixture=${base} meters=${meters.length} badge=${JSON.stringify(badgeChoice(sections))}`);
            log(`  meters: ${meters.map((m) => `[${m.label}=${m.percentage}%]`).join(" ")}`);
        }
    }
    if (failures.length) fail(failures);
    process.exit(0);
}

const FIXTURE_HTML = path.join(here, "fixtures", `${fixtureName}.html`);
const FIXTURE_EXPECTED = path.join(here, "fixtures", `${fixtureName}.expected.json`);

// ---- 1. Locate fixture files ------------------------------------------------

if (!fs.existsSync(FIXTURE_HTML)) {
    fail([`fixture HTML not found: ${FIXTURE_HTML}`]);
}
if (!fs.existsSync(FIXTURE_EXPECTED)) {
    fail([`fixture expectations not found: ${FIXTURE_EXPECTED}`]);
}

const html = fs.readFileSync(FIXTURE_HTML, "utf8");
const expected = JSON.parse(fs.readFileSync(FIXTURE_EXPECTED, "utf8"));

// ---- 2. Extract scraper JS literals from Swift source -----------------------

function extractSwiftLiteral(swift, name) {
    // Matches:  static let <name> = """\n ... \n"""
    const re = new RegExp(
        `static\\s+let\\s+${name}\\s*=\\s*"""([\\s\\S]*?)"""`,
        "m",
    );
    const m = swift.match(re);
    if (!m) return null;
    // Swift triple-quoted strings escape backslashes for JS regexes (\\d → \d
    // when the JS literal is parsed). The Swift literal in our source uses \\d
    // because Swift interprets the first backslash. After Swift strips one
    // level, the JS engine sees \d. We're reading the raw Swift source here
    // so we have to do that strip ourselves.
    return m[1].replace(/\\\\/g, "\\");
}

const swift = fs.readFileSync(SRC, "utf8");
const scrapeUsageJS = extractSwiftLiteral(swift, "scrapeUsageJS");
const scrapeSessionPercentageJS = extractSwiftLiteral(
    swift,
    "scrapeSessionPercentageJS",
);

if (!scrapeUsageJS) fail([`could not extract scrapeUsageJS from ${SRC}`]);
if (!scrapeSessionPercentageJS) {
    fail([
        `could not extract scrapeSessionPercentageJS from ${SRC}`,
        `(badge has no fallback path — restore static let scrapeSessionPercentageJS)`,
    ]);
}

// ---- 3. Run scrapers in jsdom -----------------------------------------------

const dom = new JSDOM(html, {
    url: "https://claude.ai/settings/usage",
    runScripts: "outside-only",
});
const { window } = dom;
// The scrapers are IIFEs referencing `document` and `XPathResult` directly,
// which jsdom exposes as globals when `runScripts` is enabled.
const evalIn = (code) => window.eval(code);

let usageRaw, percentage;
try {
    usageRaw = evalIn(scrapeUsageJS);
    percentage = evalIn(scrapeSessionPercentageJS);
} catch (e) {
    fail([`scraper threw: ${e.message}`]);
}

let meters;
try {
    meters = JSON.parse(usageRaw);
} catch (e) {
    fail([
        `scrapeUsageJS did not return valid JSON`,
        `raw: ${String(usageRaw).slice(0, 200)}`,
    ]);
}

// ---- 4. Validate against expectations --------------------------------------

const reasons = [];

const u = expected.scrapeUsageJS || {};
if (typeof u.minMeters === "number" && meters.length < u.minMeters) {
    reasons.push(
        `scrapeUsageJS: expected ≥${u.minMeters} meters, got ${meters.length}`,
    );
}
if (Array.isArray(u.requireLabels)) {
    const lower = meters.map((m) => String(m.label || "").toLowerCase());
    for (const needle of u.requireLabels) {
        const hit = lower.some((l) => l.includes(needle.toLowerCase()));
        if (!hit) {
            reasons.push(
                `scrapeUsageJS: no meter label contains "${needle}" (got: ${JSON.stringify(meters.map((m) => m.label))})`,
            );
        }
    }
}
if (Array.isArray(u.requirePercentages)) {
    const got = new Set(meters.map((m) => m.percentage));
    for (const p of u.requirePercentages) {
        if (!got.has(p)) reasons.push(`scrapeUsageJS: missing percentage ${p}`);
    }
}

const s = expected.scrapeSessionPercentageJS || {};
if (typeof s.expected === "number" && percentage !== s.expected) {
    reasons.push(
        `scrapeSessionPercentageJS: expected ${s.expected}, got ${percentage}`,
    );
}

const f = expected.sessionPercentageFromModel || {};
if (typeof f.expected === "number") {
    // Mirror the Swift sessionPercentage(from:) lookup so we test the *full*
    // badge path, not just the JS scrape in isolation.
    const needle = String(f.matchLabelContains || "current session").toLowerCase();
    const hit = meters.find((m) =>
        String(m.label || "").toLowerCase().includes(needle),
    );
    if (!hit) {
        reasons.push(
            `sessionPercentageFromModel: no meter label contains "${needle}" — badge would fall back to direct XPath`,
        );
    } else if (hit.percentage !== f.expected) {
        reasons.push(
            `sessionPercentageFromModel: expected ${f.expected}, got ${hit.percentage} from label "${hit.label}"`,
        );
    }
}

// ---- 5. Report -------------------------------------------------------------

if (reasons.length) fail(reasons);

log(`PASS — fixture=${fixtureName} meters=${meters.length} session%=${percentage}`);
log(`  meters: ${meters.map((m) => `[${m.label}=${m.percentage}%]`).join(" ")}`);
process.exit(0);
