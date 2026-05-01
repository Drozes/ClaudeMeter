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
    const SAMPLE = path.join(here, "fixtures", "usage-api.sample.json");
    const EXPECTED = path.join(here, "fixtures", "usage-api.expected.json");
    if (!fs.existsSync(SAMPLE)) fail([`fixture not found: ${SAMPLE}`]);
    if (!fs.existsSync(EXPECTED)) fail([`fixture not found: ${EXPECTED}`]);

    const sample = JSON.parse(fs.readFileSync(SAMPLE, "utf8"));
    const expectedJson = JSON.parse(fs.readFileSync(EXPECTED, "utf8"));

    // Mirror Swift normalizeJSONResponse. Keep behavior in lockstep with the
    // Swift implementation so this validator catches normalization drift.
    const pct = (w) => {
        if (typeof w.percent_used === "number") return w.percent_used;
        if (typeof w.utilization === "number") {
            const scaled = w.utilization <= 1.0 ? w.utilization * 100 : w.utilization;
            return Math.round(scaled);
        }
        return 0;
    };
    const detail = (w) => (w.resets_at ? `Resets ${w.resets_at}` : "");
    const meters = [];
    if (sample.session) {
        meters.push({
            label: sample.session.label || "Current session",
            percentage: pct(sample.session),
            detail: detail(sample.session),
        });
    }
    if (sample.weekly) {
        meters.push({
            label: sample.weekly.label || "Weekly usage",
            percentage: pct(sample.weekly),
            detail: detail(sample.weekly),
        });
    }
    if (Array.isArray(sample.per_model)) {
        for (const w of sample.per_model) {
            const model = w.model || "";
            const baseLabel = w.label || (model ? `Weekly ${model} usage` : "Weekly");
            meters.push({ label: baseLabel, percentage: pct(w), detail: detail(w) });
        }
    }

    const reasons = [];
    const u = expectedJson.normalizeJSONResponse || {};
    if (typeof u.minMeters === "number" && meters.length < u.minMeters) {
        reasons.push(`normalizeJSONResponse: expected >=${u.minMeters} meters, got ${meters.length}`);
    }
    if (Array.isArray(u.requireLabels)) {
        const lower = meters.map((m) => String(m.label || "").toLowerCase());
        for (const needle of u.requireLabels) {
            const hit = lower.some((l) => l.includes(needle.toLowerCase()));
            if (!hit) {
                reasons.push(
                    `normalizeJSONResponse: no meter label contains "${needle}" (got: ${JSON.stringify(meters.map((m) => m.label))})`,
                );
            }
        }
    }
    if (Array.isArray(u.requirePercentages)) {
        const got = new Set(meters.map((m) => m.percentage));
        for (const p of u.requirePercentages) {
            if (!got.has(p)) reasons.push(`normalizeJSONResponse: missing percentage ${p}`);
        }
    }
    const f = expectedJson.sessionPercentageFromModel || {};
    if (typeof f.expected === "number") {
        const needle = String(f.matchLabelContains || "current session").toLowerCase();
        const hit = meters.find((m) => String(m.label || "").toLowerCase().includes(needle));
        if (!hit) {
            reasons.push(`sessionPercentageFromModel: no meter label contains "${needle}"`);
        } else if (hit.percentage !== f.expected) {
            reasons.push(`sessionPercentageFromModel: expected ${f.expected}, got ${hit.percentage} from label "${hit.label}"`);
        }
    }

    if (reasons.length) fail(reasons);
    log(`PASS — fixture=json meters=${meters.length}`);
    log(`  meters: ${meters.map((m) => `[${m.label}=${m.percentage}%]`).join(" ")}`);
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
