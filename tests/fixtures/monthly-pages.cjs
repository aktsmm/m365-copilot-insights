"use strict";

function fixture() {
  const counts = [0, 4, 5, 6, 9, 10, 11, 14, 15, 16, 29, 30, 31];
  const departments = ["営業（合成）", "開発（合成）", "サポート（合成）"];
  const dates = (month, days) => Array.from({ length: days }, (_, i) =>
    month + "-" + String(i + 1).padStart(2, "0"));
  const rows = counts.map((count, i) => ({
    userId: "synthetic-public-" + String(i + 1).padStart(2, "0"),
    upn: "demo" + String(i + 1).padStart(2, "0") + "@example.invalid",
    displayName: "合成デモ利用者 " + String(i + 1).padStart(2, "0"),
    department: departments[i % departments.length],
    count, observedCount: count, knownDays: 30, unknownDays: 0, status: "known"
  }));
  rows.push({
    userId: "synthetic-public-unknown", upn: "unknown@example.invalid",
    displayName: "合成デモ利用者 不明", department: departments[0],
    count: null, observedCount: 0, knownDays: 29, unknownDays: 1, status: "unknown"
  });
  const complete = {
    month: "2026-09", metricId: "synthetic-submitted-prompts",
    metricLabelJa: "送信プロンプト数（完全合成・実績ではない）",
    metricLabelEn: "Submitted prompts (fully synthetic, not actual usage)",
    source: "independent-synthetic-pages-fixture-v1", dateBasis: "UTC synthetic date",
    reportRefreshDate: "2026-10-02",
    coverage: { expectedDates: dates("2026-09", 30), availableDates: dates("2026-09", 30),
      missingDates: [], status: "complete" },
    rows
  };
  const partial = structuredClone(complete);
  partial.month = "2026-10";
  partial.reportRefreshDate = "2026-10-28";
  partial.coverage = {
    expectedDates: dates("2026-10", 31),
    availableDates: ["2026-10-01", "2026-10-02"],
    missingDates: dates("2026-10", 31).slice(2), status: "in-progress"
  };
  partial.rows = rows.map(r => ({
    ...r, count: null, observedCount: r.observedCount,
    knownDays: 2, unknownDays: 29, status: "unknown"
  }));
  return {
    schemaVersion: 1, dataClass: "synthetic",
    generatedAt: "2026-10-28T00:00:00Z", months: [complete, partial]
  };
}

module.exports = fixture;
if (require.main === module) process.stdout.write(JSON.stringify(fixture()));
