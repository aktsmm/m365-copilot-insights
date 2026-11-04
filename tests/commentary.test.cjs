'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {aggregate, validate, render} = require('../scripts/Copilot.Commentary.cjs');
const payload = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/public-measured-monthly.json'), 'utf8'));
const summary = aggregate(payload);
const make = () => ({schemaVersion: 1, inputSha256: summary.inputSha256,
  observations: summary.series.map(s => ({seriesId: s.id, text: '取得できた日の参考値です。欠測があるため、期間全体の利用は断定できません。'}))});

test('aggregate matches source totals per department and removes all personal fields', () => {
  const allowed = ['department', 'people', 'observedTotal', 'confirmedTotal', 'unknownPeople'];
  for (const series of summary.series) {
    const source = payload.months.find(m => `${m.month}/${m.metricId}` === series.id);
    assert.equal(series.observedTotal, series.availableDays ? source.rows.reduce((sum, r) => sum + r.observedCount, 0) : null);
    assert.equal(series.people, source.rows.length);
    for (const group of series.departments) {
      assert.deepEqual(Object.keys(group).sort(), allowed.sort());
      const rows = source.rows.filter(r => (r.department || '(department unknown)') === group.department);
      assert.equal(group.people, rows.length);
      assert.equal(group.observedTotal, series.availableDays ? rows.reduce((sum, r) => sum + r.observedCount, 0) : null);
      assert.equal(group.confirmedTotal, rows.some(r => r.count === null) ? null : rows.reduce((sum, r) => sum + r.count, 0));
    }
  }
  assert.doesNotMatch(JSON.stringify(summary), /userId|displayName|upn|demo-user|@/);
  assert.deepEqual(aggregate(payload), summary);
});
test('empty coverage is unknown, not zero; changed input invalidates commentary', () => {
  const changed = structuredClone(payload);
  changed.months[0].coverage.availableDates = [];
  assert.equal(aggregate(changed).series.find(s => s.id === `${changed.months[0].month}/${changed.months[0].metricId}`).observedTotal, null);
  assert.throws(() => validate(make(), aggregate(changed)), /digest/);
});
test('commentary rejects identities, markup, extra fields, duplicate series and invented figures', () => {
  assert.equal(validate(make(), summary).observations.length, summary.series.length);
  for (const text of ['<script>alert("bad")</script>', '架空の利用率は100%です', '連絡先はperson@example.orgです', '詳細はhttps://example.orgです']) {
    const value = make(); value.observations[0].text = text;
    assert.throws(() => validate(value, summary));
  }
  const extra = make(); extra.secret = 'unexpected'; assert.throws(() => validate(extra, summary));
  const duplicate = make(); duplicate.observations.push({...duplicate.observations[0]}); assert.throws(() => validate(duplicate, summary));
  const badSeries = make(); badSeries.observations[0].seriesId = 'unknown'; assert.throws(() => validate(badSeries, summary));
  const missing = make(); missing.observations.pop(); assert.throws(() => validate(missing, summary));
});
test('render separates computed evidence and AI text, escapes content and links the actual inference run', () => {
  const value = make(); value.observations[0].text = '欠測があるため「A & B」の比較も確定できません。';
  const html = render(summary, value, '123');
  assert.match(html, /A &amp; B/);
  assert.match(html, /AI による参考解釈/);
  assert.match(html, /actions\/runs\/123/);
  assert.match(render(summary, null), /AI 解説がありません/);
  assert.throws(() => render(summary, value, '123?malicious'));
});
