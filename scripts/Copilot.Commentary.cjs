'use strict';
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');

const hash = value => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const escape = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const keys = (value, expected) => value && typeof value === 'object' && !Array.isArray(value) &&
  Object.keys(value).sort().join(',') === [...expected].sort().join(',');

function aggregate(payload) {
  if (payload.schemaVersion !== 1 || payload.dataClass !== 'tenant' || !Array.isArray(payload.months)) {
    throw new Error('Expected the validated public measured payload');
  }
  const series = payload.months.map(month => {
    const windowStart = new Date(`${month.reportRefreshDate}T00:00:00Z`);
    windowStart.setUTCDate(windowStart.getUTCDate() - 7);
    const oldestRecoverable = windowStart.toISOString().slice(0, 10);
    const departments = new Map();
    for (const row of month.rows) {
      if (!Number.isSafeInteger(row.observedCount) || row.observedCount < 0 ||
          !(row.count === null || (Number.isSafeInteger(row.count) && row.count >= 0))) {
        throw new Error('Invalid public count');
      }
      const name = row.department || '(department unknown)';
      const entry = departments.get(name) || {department: name, people: 0, observedTotal: 0, confirmedTotal: 0, unknownPeople: 0};
      entry.people++;
      entry.observedTotal += row.observedCount;
      if (row.count === null) entry.unknownPeople++;
      else entry.confirmedTotal += row.count;
      departments.set(name, entry);
    }
    const availableDays = month.coverage.availableDates.length;
    const groups = [...departments.values()].sort((a, b) => a.department.localeCompare(b.department, 'en'));
    for (const entry of groups) {
      if (!availableDays) entry.observedTotal = null;
      if (entry.unknownPeople) entry.confirmedTotal = null;
    }
    return {
      id: `${month.month}/${month.metricId}`, month: month.month, metricId: month.metricId,
      source: month.source, reportRefreshDate: month.reportRefreshDate,
      availableDays, missingDays: month.coverage.missingDates.length,
      afterRefreshDays: month.coverage.missingDates.filter(d => d > month.reportRefreshDate).length,
      expiredMissingDays: month.coverage.missingDates.filter(d => d < oldestRecoverable).length,
      recoverableMissingDays: month.coverage.missingDates.filter(d => d >= oldestRecoverable && d <= month.reportRefreshDate).length,
      people: month.rows.length,
      observedTotal: availableDays ? groups.reduce((sum, d) => sum + d.observedTotal, 0) : null,
      confirmedTotal: groups.some(d => d.confirmedTotal === null) ? null : groups.reduce((sum, d) => sum + d.confirmedTotal, 0),
      departments: groups
    };
  }).sort((a, b) => a.id.localeCompare(b.id, 'en'));
  const input = {
    schemaVersion: 1, dataClass: 'public-measured-aggregate',
    sourceGeneratedAt: payload.generatedAt,
    rules: {
      unknownIsZero: false, metricsAreInterchangeable: false, includesViva: false, includesAudit: false,
      reportRetrievalDaysBeforeRefresh: 7, expiredUnsavedDatesCannotBeRecovered: true,
      missingDaysIncludesDatesAfterReportRefresh: true
    },
    series
  };
  return {...input, inputSha256: hash(input)};
}

function validate(commentary, summary) {
  if (!keys(commentary, ['schemaVersion', 'inputSha256', 'observations']) ||
      commentary.schemaVersion !== 1 || commentary.inputSha256 !== summary.inputSha256 ||
      !Array.isArray(commentary.observations) || !commentary.observations.length ||
      commentary.observations.length !== summary.series.length) {
    throw new Error('Commentary contract or aggregate digest mismatch');
  }
  const ids = new Set();
  for (const item of commentary.observations) {
    if (!keys(item, ['seriesId', 'text']) || !summary.series.some(s => s.id === item.seriesId) ||
        ids.has(item.seriesId) || typeof item.text !== 'string' || item.text.length < 10 || item.text.length > 420 ||
        /[\u0000-\u001f<>@0-9０-９]/u.test(item.text) || /https?:|www\./i.test(item.text)) {
      throw new Error('Invalid observation: use a unique series and short plain qualitative text, without numbers, links or identities');
    }
    ids.add(item.seriesId);
  }
  return commentary;
}

function render(summary, commentary, runId) {
  if (commentary) validate(commentary, summary);
  if (runId && !/^[1-9]\d*$/.test(runId)) throw new Error('Invalid inference run ID');
  const shown = n => n === null ? '不明' : String(n);
  const rows = summary.series.map((s, i) => `<tr><td>${i + 1}</td><td>${escape(s.month)}</td><td>${s.metricId === 'all-apps-actions' ? 'アクション数' : 'プロンプト数'}</td><td>${s.availableDays}</td><td>${s.missingDays}</td><td>${shown(s.observedTotal)}</td><td>${shown(s.confirmedTotal)}</td></tr>`).join('');
  const text = commentary ? commentary.observations.map(o => `<p><b>${escape(o.seriesId)}</b>: ${escape(o.text)}</p>`).join('') :
    '<p>このビルドには AI 解説がありません。集計表はスクリプトが生成した値で、AI の出力ではありません。</p>';
  return `<section id="ai-commentary" style="padding:1rem;background:var(--cp-surface);color:var(--cp-text)"><h2>集計の読み取りと AI 解説</h2><p>取得元は公開承認済みの Graph 日別レポートと Entra 部門属性です。スクリプトが部門別・月別・指標別に集計し、AI は個票や氏名ではなく、その集計だけを読みます。ライブの Microsoft 365 / Viva / Purview には接続しません。</p><table><thead><tr><th>#</th><th>月</th><th>指標</th><th>取得日数</th><th>未取得日数（基準日後を含む）</th><th>観測合計（参考）</th><th>確定合計</th></tr></thead><tbody>${rows}</tbody></table><p>上表は決定論的な集計です。未取得日数には月内のレポート基準日後の日も含み、それ自体は収集障害ではありません。取得窓外の未保存日は復元できず、再取得の対象は基準日の七日前から基準日までだけです。観測合計は取得できた日だけの値で、欠測をゼロとみなさず、指標同士を足し合わせません。以下は AI による参考解釈で、原本の事実・確定評価ではありません。</p>${text}<p><a href="measured-aggregate.json">AI が読む部門別集計 JSON</a>${commentary ? ' / <a href="commentary.json">AI 出力 JSON</a> / <a href="commentary-provenance.json">解説の出典・成果物情報</a>' : ''}${runId ? ` / <a href="https://github.com/aktsmm/m365-copilot-insights/actions/runs/${runId}">推論の実行記録</a>` : ''}</p><p>集計の識別子: <code>${summary.inputSha256}</code>。公開データを更新した場合、古い解説はこの識別子の不一致で掲載を拒否します。</p></section>`;
}

if (require.main === module) {
  const [mode, payloadFile, output, commentaryFile, runId] = process.argv.slice(2);
  const summary = aggregate(JSON.parse(fs.readFileSync(payloadFile, 'utf8').replace(/^\uFEFF/, '')));
  fs.mkdirSync(path.dirname(output), {recursive: true});
  if (mode === 'aggregate') fs.writeFileSync(output, JSON.stringify(summary, null, 2) + '\n');
  else if (mode === 'render') {
    const commentary = commentaryFile ? JSON.parse(fs.readFileSync(commentaryFile, 'utf8')) : null;
    fs.writeFileSync(output, render(summary, commentary, runId));
    fs.writeFileSync(path.join(path.dirname(output), 'measured-aggregate.json'), JSON.stringify(summary, null, 2) + '\n');
    if (commentary) fs.writeFileSync(path.join(path.dirname(output), 'commentary.json'), JSON.stringify(commentary, null, 2) + '\n');
  } else throw new Error('Expected aggregate or render');
}
module.exports = {aggregate, validate, render};
