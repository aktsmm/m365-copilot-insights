"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { sanitize, verify, assertPublic } = require("../scripts/Export-CopilotPublicMonthly.cjs");
const fixture = require("./fixtures/monthly-pages.cjs");
const fs = require("node:fs");
const path = require("node:path");
const { createHash } = require("node:crypto");
function privateFixture() {
  const input = fixture();
  input.dataClass = "tenant";
  input.topSecret = "TOP-PRIVATE-CANARY";
  for (const month of input.months) {
    month.metricId = "all-apps-actions";
    month.metricLabelJa = "Copilotアクション数（プロンプト数とは異なる）";
    month.metricLabelEn = "Copilot actions (not prompts)";
    month.privateUrl = "https://private-canary.invalid";
    month.coverage.secret = "COVERAGE-PRIVATE-CANARY";
    for (const [i, row] of month.rows.entries()) {
      row.userId = "private-user-" + i;
      row.upn = "private" + i + "@example.invalid";
      row.displayName = "非公開氏名" + i;
      row.department = "非公開部署" + (i % 3);
      row.privateData = "ROW-PRIVATE-CANARY";
    }
  }
  return input;
}
test("public sanitizer keeps real metrics, null, coverage and grouping; strips all extra fields and source identities", () => {
  const source = privateFixture();
  const output = sanitize(source);
  assert.equal(verify(source, output).status, "passed");
  assert.equal(output.dataClass, "tenant");
  assert.equal(output.months[0].rows[0].count, 0);
  assert.equal(output.months[0].rows.at(-1).count, null);
  assert.equal(output.months[1].rows[0].count, null);
  assert.equal(output.months[0].rows[0].department, output.months[0].rows[3].department);
  assert(!JSON.stringify(output).includes("PRIVATE-CANARY"));
  assert(!JSON.stringify(output).includes("private-canary"));
  assert.deepEqual(sanitize(source), output);
});
test("public gate rejects relabeling, identity leaks, counts changes and unknown-field promotion", () => {
  const source = privateFixture(), clean = sanitize(source);
  const mutations = [
    p => p.dataClass = "synthetic",
    p => p.months[0].rows[0].upn = source.months[0].rows[0].upn,
    p => p.months[0].rows[0].count = 1,
    p => p.months[0].rows[0].extra = "secret",
    p => p.extra = "secret",
    p => p.months[0].source = "https://private.invalid",
    p => p.months[0].rows[0].department = source.months[0].rows[0].department,
    p => p.months[0].rows[0].department = p.months[0].rows[1].department
  ];
  for (const mutate of mutations) {
    const changed = structuredClone(clean);
    mutate(changed);
    assert.throws(() => verify(source, changed));
  }
  assertPublic(clean);
});
test("reviewed measured export is pinned and retains unknown rather than fabricated zero", () => {
  const raw = fs.readFileSync(path.join(__dirname, "fixtures/public-measured-monthly.json"), "utf8")
    .replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
  const output = assertPublic(JSON.parse(raw));
  const digest = createHash("sha256").update(raw).digest("hex");
  const builder = fs.readFileSync(path.join(__dirname, "../scripts/Build-CopilotPublicPages.ps1"), "utf8");
  assert(builder.includes("'" + digest + "'"));
  for (const month of output.months) {
    if (month.coverage.status === "in-progress") {
      assert(month.rows.every(row => row.count === null && row.status === "unknown"));
    }
  }
});
