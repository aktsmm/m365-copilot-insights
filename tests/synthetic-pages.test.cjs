"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { createHash } = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const fixture = require("./fixtures/monthly-pages.cjs");
const { validate, selectRows, csv } = require("../monthly-ui/dashboard.js");
const state = { threshold: "5", department: "", search: "", view: "low", sort: "count" };

test("public fixture is independent, deterministic and reserved synthetic identities only", () => {
  const payload = validate(fixture());
  assert.equal(payload.dataClass, "synthetic");
  assert.deepEqual(fixture(), payload);
  for (const month of payload.months) {
    assert.equal(month.source, "independent-synthetic-pages-fixture-v1");
    for (const row of month.rows) {
      assert.match(row.upn, /^[a-z0-9]+@example\.invalid$/);
      assert.match(row.userId, /^synthetic-public-/);
      assert.match(row.displayName, /^合成デモ利用者 /);
      assert.match(row.department, /（合成）$/);
    }
  }
  const fixtureText = fs.readFileSync(path.join(__dirname, "fixtures/monthly-pages.cjs"), "utf8")
    .replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
  const digest = createHash("sha256").update(fixtureText).digest("hex");
  const builder = fs.readFileSync(path.join(__dirname, "../scripts/Build-CopilotSyntheticPages.ps1"), "utf8");
  assert(builder.includes("'" + digest + "'"), "public fixture source digest must be reviewed and pinned");
});

test("public demo covers all threshold boundaries, department and unknown without zero filling", () => {
  const [complete, partial] = validate(fixture()).months;
  for (const n of [5, 10, 15, 30, 12]) {
    const selected = selectRows(complete, { ...state, threshold: String(n) });
    assert.deepEqual(selected.map(r => r.count),
      complete.rows.filter(r => r.status === "known" && r.count < n).map(r => r.count));
    assert(selected.every(r => r.count !== null && r.count < n));
  }
  const department = "営業（合成）";
  const scoped = selectRows(complete, { ...state, threshold: "30", department });
  assert(scoped.length > 0 && scoped.every(r => r.department === department));
  assert.equal(selectRows(complete, { ...state, view: "unknown" }).length, 1);
  assert.equal(selectRows(partial, state).length, 0);
  assert.equal(selectRows(partial, { ...state, view: "unknown" }).length, partial.rows.length);
  const output = csv(complete, scoped);
  assert(output.startsWith("\uFEFF"));
  assert.equal(output.split("\r\n").length - 2, scoped.length);
  scoped.forEach(r => assert(output.includes('"' + r.userId + '"')));
});
