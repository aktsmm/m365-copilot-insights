"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const assert = require("node:assert/strict");
const { validate } = require("../monthly-ui/dashboard.js");
const monthFields = ["month", "metricId", "metricLabelJa", "metricLabelEn", "dateBasis", "source", "reportRefreshDate"];
const coverageFields = ["expectedDates", "availableDates", "missingDates", "status"];
const numericFields = ["count", "observedCount", "knownDays", "unknownDays", "status"];
const rowFields = ["userId", "upn", "displayName", "department", ...numericFields];
const pick = (source, fields) => Object.fromEntries(fields.map(key => [key, structuredClone(source[key])]));
const numbered = (n, width) => String(n).padStart(width, "0");

function assertPublic(payload) {
  validate(payload);
  assert.equal(payload.dataClass, "tenant", "Measured values must never be relabeled synthetic");
  assert.deepEqual(Object.keys(payload).sort(), ["schemaVersion", "dataClass", "generatedAt", "months"].sort());
  for (const month of payload.months) {
    assert.deepEqual(Object.keys(month).sort(), [...monthFields, "coverage", "rows"].sort());
    assert.deepEqual(Object.keys(month.coverage).sort(), [...coverageFields].sort());
    assert.equal(month.metricId, "all-apps-actions", "This public approval is for observed actions, not prompts");
    for (const [index, row] of month.rows.entries()) {
      const id = "demo-user-" + numbered(index + 1, 3);
      assert.deepEqual(Object.keys(row).sort(), [...rowFields].sort());
      assert.equal(row.userId, id);
      assert.equal(row.upn, id + "@example.invalid");
      assert.equal(row.displayName, "デモ利用者 " + numbered(index + 1, 3));
      assert.match(row.department, /^部門 [0-9]{2,}$/);
    }
  }
  const serialized = JSON.stringify(payload);
  assert(!/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i.test(serialized), "Management GUID is not public");
  assert(!/https?:\/\/|sharepoint\.com|onmicrosoft\.com|access_token|client_secret|Bearer\s/i.test(serialized), "Internal URL or credential marker is not public");
  const emails = serialized.match(/[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/gi) || [];
  assert(emails.every(value => /^demo-user-[0-9]{3,}@example\.invalid$/.test(value)), "Original account address is not public");
  return payload;
}

function sanitize(source) {
  validate(source);
  assert.equal(source.dataClass, "tenant");
  const departments = new Map();
  const result = {
    schemaVersion: source.schemaVersion, dataClass: "tenant", generatedAt: source.generatedAt,
    months: source.months.map(month => ({
      ...pick(month, monthFields), coverage: pick(month.coverage, coverageFields),
      rows: month.rows.map((row, index) => {
        if (!departments.has(row.department)) departments.set(row.department, "部門 " + numbered(departments.size + 1, 2));
        const id = "demo-user-" + numbered(index + 1, 3);
        return {
          userId: id, upn: id + "@example.invalid",
          displayName: "デモ利用者 " + numbered(index + 1, 3),
          department: departments.get(row.department), ...pick(row, numericFields)
        };
      })
    }))
  };
  assertPublic(result);
  verify(source, result);
  return result;
}

function verify(source, output) {
  assertPublic(output);
  assert.equal(output.schemaVersion, source.schemaVersion);
  assert.equal(output.generatedAt, source.generatedAt);
  assert.equal(output.months.length, source.months.length);
  const groups = new Map(), reverseGroups = new Map();
  for (const [index, original] of source.months.entries()) {
    const published = output.months[index];
    assert.deepEqual(pick(published, monthFields), pick(original, monthFields));
    assert.deepEqual(published.coverage, pick(original.coverage, coverageFields));
    assert.equal(published.rows.length, original.rows.length);
    assert.equal(new Set(published.rows.map(row => row.userId)).size, new Set(original.rows.map(row => row.userId)).size);
    for (const [rowIndex, row] of original.rows.entries()) {
      const publicRow = published.rows[rowIndex];
      assert.deepEqual(pick(publicRow, numericFields), pick(row, numericFields), "Observed values must be identical");
      if (groups.has(row.department)) assert.equal(groups.get(row.department), publicRow.department);
      if (reverseGroups.has(publicRow.department)) assert.equal(reverseGroups.get(publicRow.department), row.department);
      groups.set(row.department, publicRow.department);
      reverseGroups.set(publicRow.department, row.department);
    }
  }
  const serialized = JSON.stringify(output).toLocaleLowerCase();
  for (const month of source.months) {
    for (const row of month.rows) {
      for (const field of ["userId", "upn", "displayName", "department"]) {
        if (row[field]) assert(!serialized.includes(row[field].toLocaleLowerCase()), "Original identity or department text is not public");
      }
    }
  }
  return {
    status: "passed", months: output.months.length,
    rowCounts: output.months.map(month => month.rows.length),
    uniqueCounts: output.months.map(month => new Set(month.rows.map(row => row.userId)).size),
    checks: ["measured-values-identical", "coverage-arrays-identical", "metadata-identical",
      "row-and-unique-counts-identical", "department-grouping-identical",
      "original-identities-and-departments-absent", "management-identifiers-and-internal-urls-absent",
      "canonical-fields-only", "tenant-dataclass-preserved"]
  };
}

module.exports = { sanitize, verify, assertPublic };
if (require.main === module) {
  const [sourcePath, outputPath, evidencePath] = process.argv.slice(2);
  if (!sourcePath || !outputPath || !evidencePath) throw new Error("Usage: node Export-CopilotPublicMonthly.cjs <private-source> <public-output> <private-gate-evidence>");
  if (fs.existsSync(outputPath) || fs.existsSync(evidencePath)) throw new Error("Outputs must not already exist");
  const sourceBytes = fs.readFileSync(sourcePath);
  const source = JSON.parse(sourceBytes.toString("utf8").replace(/^\uFEFF/, ""));
  const output = sanitize(source);
  const bytes = JSON.stringify(output, null, 2) + "\n";
  const report = verify(source, output);
  report.publicPayloadSha256 = crypto.createHash("sha256").update(bytes).digest("hex");
  report.privateSourceSha256 = crypto.createHash("sha256").update(sourceBytes).digest("hex");
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.mkdirSync(path.dirname(evidencePath), { recursive: true });
  fs.writeFileSync(outputPath, bytes, { encoding: "utf8", flag: "wx" });
  fs.writeFileSync(evidencePath, JSON.stringify(report, null, 2) + "\n", { encoding: "utf8", flag: "wx" });
  process.stdout.write(JSON.stringify({ status: report.status, months: report.months, rowCounts: report.rowCounts, publicPayloadSha256: report.publicPayloadSha256 }) + "\n");
}
