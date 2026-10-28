(function (global) {
  "use strict";
  const isInt = n => Number.isSafeInteger(n) && n >= 0;
  const text = n => typeof n === "string" && n.trim().length > 0;
  const date = n => typeof n === "string" && /^\d{4}-\d{2}-\d{2}$/.test(n) && new Date(n + "T00:00:00Z").toISOString().slice(0, 10) === n;
  function validate(payload) {
    const fail = message => { throw new Error("Invalid monthly payload: " + message); };
    if (!payload || payload.schemaVersion !== 1 || !["tenant", "synthetic"].includes(payload.dataClass) ||
      !text(payload.generatedAt) || !Number.isFinite(Date.parse(payload.generatedAt)) ||
      !Array.isArray(payload.months) || !payload.months.length) fail("schema / generatedAt / months");
    const keys = new Set();
    payload.months.forEach(m => {
      if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(m.month) ||
        !["metricId", "metricLabelJa", "metricLabelEn", "dateBasis", "source"].every(k => text(m[k])) ||
        !date(m.reportRefreshDate)) fail("month metadata");
      const key = JSON.stringify([m.month, m.metricId, m.source]);
      if (keys.has(key)) fail("duplicate month / metric / source");
      keys.add(key);
      const c = m.coverage;
      if (!c || !["complete", "partial", "in-progress"].includes(c.status) ||
        !["expectedDates", "availableDates", "missingDates"].every(k => Array.isArray(c[k]) &&
          c[k].every(d => date(d) && d.startsWith(m.month + "-")) && new Set(c[k]).size === c[k].length)) fail("coverage");
      const expected = new Set(c.expectedDates), available = new Set(c.availableDates), missing = new Set(c.missingDates);
      if (!expected.size || [...available, ...missing].some(d => !expected.has(d)) ||
        [...available].some(d => missing.has(d)) || expected.size !== available.size + missing.size ||
        (c.status === "complete" && missing.size)) fail("coverage partition");
      const end = new Date(m.month + "-01T00:00:00Z");
      end.setUTCMonth(end.getUTCMonth() + 1);
      end.setUTCDate(0);
      const days = end.getUTCDate();
      if (c.status === "complete" && expected.size !== days) fail("complete month must cover every calendar date");
      if (!Array.isArray(m.rows)) fail("rows");
      const users = new Set();
      m.rows.forEach(r => {
        if (!text(r.userId) || !text(r.upn) || typeof r.displayName !== "string" || typeof r.department !== "string" ||
          users.has(r.userId) || !isInt(r.knownDays) || !isInt(r.unknownDays) ||
          r.knownDays + r.unknownDays !== expected.size ||
          !["known", "unknown"].includes(r.status) ||
          !(r.count === null || isInt(r.count)) || !(r.observedCount === null || isInt(r.observedCount))) fail("row");
        users.add(r.userId);
        const known = c.status !== "in-progress" && r.unknownDays === 0 && r.knownDays === days;
        if (r.status === "known" && (!known || r.count === null)) fail("known count without complete coverage");
        if (r.status === "unknown" && r.count !== null) fail("unknown must have null count");
        if (!known && r.count !== null) fail("incomplete row count must be null");
      });
    });
    return payload;
  }
  function selectRows(month, state) {
    if (!/^(0|[1-9]\d*)$/.test(String(state.threshold)) || !isInt(Number(state.threshold))) throw new Error("しきい値は0以上の整数を入力してください / Enter a non-negative integer.");
    const q = state.search.trim().toLocaleLowerCase();
    return month.rows.map((row, index) => ({ row, index })).filter(({ row: r }) =>
      (!state.department || r.department === state.department) &&
      (!q || (r.displayName + " " + r.upn).toLocaleLowerCase().includes(q)) &&
      (state.view === "all" || (state.view === "mtd" ? isInt(r.observedCount) && r.knownDays > 0 && r.observedCount < Number(state.threshold) : state.view === "unknown" ? r.status === "unknown" :
        r.status === "known" && r.count !== null && r.count < Number(state.threshold))))
      .sort((a, b) => {
        const x = a.row, y = b.row;
        let order;
        if (state.sort === "count") { const a1 = state.view === "mtd" ? x.observedCount : x.count, b1 = state.view === "mtd" ? y.observedCount : y.count; order = a1 === null ? (b1 === null ? 0 : 1) : b1 === null ? -1 : a1 - b1; }
        else if (state.sort === "observedCount") { const a1 = x.observedCount, b1 = y.observedCount; order = a1 === null ? (b1 === null ? 0 : 1) : b1 === null ? -1 : b1 - a1; }
        else order = String(x[state.sort]).localeCompare(String(y[state.sort]), "ja");
        return order || a.index - b.index;
      }).map(x => x.row);
  }
  function ranges(dates) {
    const days = [...dates].sort(), out = [];
    let start = null, prev = null;
    const day = s => Date.UTC(+s.slice(0, 4), +s.slice(5, 7) - 1, +s.slice(8, 10)) / 864e5;
    const flush = () => { if (start) out.push(start === prev ? start.slice(5) : start.slice(5) + "〜" + prev.slice(5)); };
    for (const d of days) { if (start && day(d) === day(prev) + 1) prev = d; else { flush(); start = prev = d; } }
    flush();
    return out.join(", ");
  }
  function csv(month, rows) {
    const headers = ["month", "metricId", "source", "dateBasis", "reportRefreshDate", "coverage", "userId", "upn", "displayName", "department", "count", "observedCount", "knownDays", "unknownDays", "status"];
    const cell = v => {
      let s = v === null || v === undefined ? "" : String(v);
      if (/^[\s\uFEFF]*[=+\-@]/.test(s) || /^[\t\r\n]/.test(s)) s = "'" + s;
      return '"' + s.replace(/"/g, '""') + '"';
    };
    return "\uFEFF" + [headers, ...rows.map(r => [month.month, month.metricId, month.source, month.dateBasis, month.reportRefreshDate, month.coverage.status, ...headers.slice(6).map(k => r[k])])].map(r => r.map(cell).join(",")).join("\r\n") + "\r\n";
  }
  const labels = {
    ja: { title: "Copilot 月次利用状況", language: "English", month: "対象月", metric: "指標・ソース", department: "部門（集計時点）", search: "氏名 / UPN 検索", threshold: "しきい値（厳密に未満）", preset: "しきい値プリセット", view: "表示対象", low: "しきい値未満（確定値のみ）", mtd: "月初来の回数がしきい値未満（参考値）", mtdNote: "月初来 = 取得済みの日だけの合計です。月が終わるまで確定ではありません。", unknown: "不明・欠測", all: "全件", sort: "並び順", count: "確定回数", displayName: "氏名", reset: "リセット", sortObserved: "観測回数（多い順・参考）", more: "さらに表示", shown: "表示", of: "件中", presetLabel: "よく使うしきい値", result: "結果 CSV", allCsv: "選択月・指標の全体 CSV", departmentCsv: "部門 CSV", source: "ソース", basis: "ソース日付基準", refresh: "レポート基準日", generated: "生成日時", complete: "完全月", partial: "取得不足・参考値", "in-progress": "当月途中・参考値", observed: "観測回数（参考のみ）", known: "既知", missing: "欠測日", empty: "該当する行がありません。", warning: "欠測・当月途中の回数は参考値です。少利用を確定できません。不明は0として扱いません。", download: "CSV / HTMLの持ち出し後には、SharePointのアクセス制御・取り消しは適用されません。", showObserved: "観測回数（参考）を表示", total: "母集団", results: "結果", unavailable: "不明", synthetic: "合成データ（実績ではありません）", tenant: "テナントデータ", kpiKnownSub: "確定済み", kpiUnknownSub: "0 ではありません", kpiCoverage: "取得カバレッジ", kpiDays: "日", kpiMedian: "観測回数 中央値", kpiMedianSub: "参考値", kpiBelow: "しきい値未満", kpiRef: "（参考）", timeline: "日別の取得状況", legendOk: "取得済み", legendMiss: "欠測", legendFuture: "未到来", histogram: "観測回数の分布（参考）" },
    en: { title: "Copilot monthly usage", language: "日本語", month: "Month", metric: "Metric / source", department: "Department (at aggregation)", search: "Name / UPN search", threshold: "Threshold (strictly less than)", preset: "Threshold presets", view: "View", low: "Below threshold (confirmed only)", mtd: "Month-to-date below threshold (reference)", mtdNote: "Month-to-date = total of the dates collected so far; not final until the month ends.", unknown: "Unknown / missing", all: "All", sort: "Sort by", count: "Confirmed count", displayName: "Name", reset: "Reset", sortObserved: "Observed count (high first, reference)", more: "Show more", shown: "Showing", of: "of", presetLabel: "Quick thresholds", result: "Results CSV", allCsv: "All CSV (selected month / metric)", departmentCsv: "Department CSV", source: "Source", basis: "Source date basis", refresh: "Report refresh date", generated: "Generated at", complete: "Complete month", partial: "Partial / reference only", "in-progress": "In progress / reference only", observed: "Observed count (reference only)", known: "Known", missing: "Missing dates", empty: "No matching rows.", warning: "Incomplete / current-month counts are reference only, not confirmed low usage. Unknown is never zero.", download: "Downloaded CSV / HTML is no longer protected or revocable by SharePoint access controls.", showObserved: "Show observed counts (reference)", total: "Population", results: "Results", unavailable: "Unknown", synthetic: "Synthetic data (not actual usage)", tenant: "Tenant data", kpiKnownSub: "Confirmed", kpiUnknownSub: "Never zero", kpiCoverage: "Collection coverage", kpiDays: "days", kpiMedian: "Observed median", kpiMedianSub: "Reference only", kpiBelow: "Below threshold", kpiRef: "(reference)", timeline: "Daily collection status", legendOk: "Collected", legendMiss: "Missing", legendFuture: "Not yet", histogram: "Observed count distribution (reference)" }
  };
  let serial = 0;
  function mount(root, input, options) {
    validate(input);
    const payload = JSON.parse(JSON.stringify(input));
    const state = { language: "ja", month: payload.months[0].month, key: "", department: "", search: "", threshold: "5", view: "low", sort: "count", observed: !!(options && options.showObservedCounts) };
    const prefix = "cp-monthly-" + (++serial) + "-";
    let disposed = false;
    function render(focus) {
      if (disposed) return;
      const t = labels[state.language];
      root.replaceChildren();
      root.classList.add("cp-monthly");
      root.lang = state.language;
      const element = (tag, content, parent = root) => {
        const n = document.createElement(tag);
        if (content !== undefined) n.textContent = content;
        parent.appendChild(n); return n;
      };
      const button = (label, action, parent) => { const b = element("button", label, parent); b.type = "button"; b.addEventListener("click", action); return b; };
      const top = element("header");
      element("h2", t.title, top);
      button(t.language, () => { state.language = state.language === "ja" ? "en" : "ja"; render(); }, top).id = prefix + "language";
      element("p", t[payload.dataClass]);
      const filters = element("div"); filters.className = "cp-filters";
      function control(key, caption, values, action) {
        const label = element("label", caption, filters);
        const n = element(values ? "select" : "input", undefined, label);
        n.id = prefix + key;
        n.setAttribute("aria-label", caption);
        if (values) values.forEach(([value, name]) => { const option = element("option", name, n); option.value = value; });
        else n.type = key === "threshold" ? "text" : "search";
        if (key === "threshold") n.inputMode = "numeric";
        n.value = String(state[key]);
        n.addEventListener(values ? "change" : "input", () => { state[key] = n.value; state.limit = 24; if (action) action(); render({ key, position: n.selectionStart }); });
        return n;
      }
      const monthNames = [...new Set(payload.months.map(m => m.month))].sort().reverse();
      control("month", t.month, monthNames.map(m => [m, m]), () => { state.key = ""; state.department = ""; });
      const choices = payload.months.map((m, i) => ({ m, i })).filter(x => x.m.month === state.month);
      if (!choices.some(x => String(x.i) === state.key)) state.key = String(choices[0].i);
      const month = payload.months[Number(state.key)];
      if (state.autoView !== month.month + "/" + state.key) { state.autoView = month.month + "/" + state.key; if (month.coverage.status !== "complete" && state.view === "low") state.view = "mtd"; state.sort = "observedCount"; }
      control("key", t.metric, choices.map(x => [String(x.i), (state.language === "ja" ? x.m.metricLabelJa : x.m.metricLabelEn) + " / " + x.m.source]), () => { state.department = ""; });
      control("department", t.department, [["", t.all], ...[...new Set(month.rows.map(r => r.department))].sort().map(d => [d, d || "—"])]);
      control("search", t.search);
      const threshold = control("threshold", t.threshold);
      const presetBox = element("div", undefined, filters); presetBox.className = "cp-presets";
      element("span", t.presetLabel, presetBox);
      const presets = element("div", undefined, presetBox);
      presets.setAttribute("role", "group"); presets.setAttribute("aria-label", t.preset);
      [5, 10, 15, 30].forEach(n => { const b = button(String(n), () => { state.threshold = String(n); render(); }, presets); if (String(n) === String(state.threshold)) b.setAttribute("aria-pressed", "true"); });
      control("view", t.view, [["low", t.low], ["mtd", t.mtd], ["unknown", t.unknown], ["all", t.all]]);
      control("sort", t.sort, [["count", t.count], ["observedCount", t.sortObserved], ["displayName", t.displayName], ["department", t.department]]);
      const observedLabel = element("label", t.showObserved, filters);
      const observed = element("input", undefined, observedLabel); observed.type = "checkbox"; observed.checked = state.observed;
      observed.addEventListener("change", () => { state.observed = observed.checked; render(); });
      button(t.reset, () => { Object.assign(state, { month: payload.months[0].month, key: "", department: "", search: "", threshold: "5", view: "low", sort: "count", observed: !!(options && options.showObservedCounts) }); render(); });
      const metadata = element("dl");
      [[t.month, month.month], [t.source, month.source], [t.basis, month.dateBasis], [t.refresh, month.reportRefreshDate], [t.generated, payload.generatedAt],
        [state.language === "ja" ? "完全性" : "Completeness", t[month.coverage.status]],
        [state.language === "ja" ? "取得日 / 期待日" : "Available / expected dates", `${month.coverage.availableDates.length} / ${month.coverage.expectedDates.length}`],
        [t.missing, ranges(month.coverage.missingDates) || "—"]].forEach(([k, v]) => { element("dt", k, metadata); element("dd", v, metadata); });
      if (month.coverage.status !== "complete") { const warning = element("p", t.warning); warning.className = "cp-warning"; if (state.view === "mtd") element("p", t.mtdNote).className = "cp-warning"; }
      element("p", t.download).className = "cp-muted";
      const error = element("p"); error.id = prefix + "error"; error.setAttribute("role", "alert");
      let rows = [];
      try { rows = selectRows(month, state); threshold.removeAttribute("aria-invalid"); }
      catch (e) { error.textContent = e.message; threshold.setAttribute("aria-invalid", "true"); threshold.setAttribute("aria-describedby", error.id); }
      const scope = month.rows.filter(r => !state.department || r.department === state.department);
      const kpis = element("div"); kpis.className = "cp-kpis";
      const pct = Math.round(month.coverage.availableDates.length / month.coverage.expectedDates.length * 100);
      const observedValues = scope.map(r => r.observedCount).filter(isInt);
      const median = observedValues.length ? [...observedValues].sort((a, b) => a - b)[Math.floor(observedValues.length / 2)] : null;
      const lowN = scope.filter(r => isInt(r.observedCount) && r.observedCount < Number(state.threshold)).length;
      [[t.total, scope.length, state.department || t.all, "var(--cp-accent)"],
        [t.known, scope.filter(r => r.status === "known").length, t.kpiKnownSub, "var(--cp-success)"],
        [t.unknown, scope.filter(r => r.status === "unknown").length, t.kpiUnknownSub, "var(--cp-warning)"],
        [t.kpiCoverage, pct + "%", `${month.coverage.availableDates.length} / ${month.coverage.expectedDates.length} ${t.kpiDays}`, "var(--cp-accent)"],
        [t.kpiMedian, median === null ? "—" : median, t.kpiMedianSub, "var(--cp-text)"],
        [t.kpiBelow, lowN, `< ${state.threshold} ${t.kpiRef}`, "var(--cp-danger)"]].forEach(([k, v, sub, color]) => {
        const tile = element("div", undefined, kpis); tile.className = "cp-kpi"; tile.style.setProperty("--cp-kpi", color);
        element("div", k, tile).className = "cp-kpi-label"; element("div", String(v), tile).className = "cp-kpi-value"; element("div", sub, tile).className = "cp-kpi-sub";
      });
      const panels = element("div"); panels.className = "cp-panels";
      const tl = element("section", undefined, panels); tl.className = "cp-panel"; element("h3", t.timeline, tl);
      const strip = element("div", undefined, tl); strip.className = "cp-timeline"; strip.setAttribute("role", "img");
      const dim = new Date(Date.UTC(Number(month.month.slice(0, 4)), Number(month.month.slice(5)), 0)).getUTCDate();
      const avail = new Set(month.coverage.availableDates), exp = new Set(month.coverage.expectedDates);
      strip.setAttribute("aria-label", `${t.timeline}: ${avail.size} / ${dim}`);
      for (let d = 1; d <= dim; d++) {
        const key = month.month + "-" + String(d).padStart(2, "0"), cell = element("i", undefined, strip);
        cell.className = avail.has(key) ? "" : exp.has(key) ? "cp-miss" : "cp-future"; cell.title = key;
      }
      const legend = element("div", undefined, tl); legend.className = "cp-legend";
      element("span", t.legendOk, legend); element("span", t.legendMiss, legend).className = "cp-l-miss"; element("span", t.legendFuture, legend).className = "cp-l-future";
      const hp = element("section", undefined, panels); hp.className = "cp-panel"; element("h3", t.histogram, hp);
      const hist = element("div", undefined, hp); hist.className = "cp-hist";
      const buckets = [["0", 0, 0], ["1–4", 1, 4], ["5–9", 5, 9], ["10–14", 10, 14], ["15–29", 15, 29], ["30+", 30, Infinity]];
      const counts = buckets.map(([, lo, hi]) => observedValues.filter(v => v >= lo && v <= hi).length);
      counts.push(scope.length - observedValues.length);
      const peak = Math.max(1, ...counts);
      [...buckets.map(b => b[0]), t.unavailable].forEach((name, i) => {
        element("span", name, hist).className = "cp-k";
        const bar = element("span", undefined, hist); bar.className = "cp-bar";
        const fill = element("b", undefined, bar); fill.style.width = (counts[i] / peak * 100) + "%"; if (i === counts.length - 1) fill.className = "cp-unk";
        element("span", String(counts[i]), hist).className = "cp-n";
      });
      const summary = element("p", `${t.total}: ${month.rows.length} · ${t.known}: ${month.rows.filter(r => r.status === "known").length} · ${t.unknown}: ${month.rows.filter(r => r.status === "unknown").length} · ${t.results}: ${rows.length}`);
      summary.setAttribute("role", "status"); summary.setAttribute("aria-live", "polite");
      const actions = element("div"); actions.className = "cp-actions";
      function download(selected, name) {
        const blob = new Blob([csv(month, selected)], { type: "text/csv;charset=utf-8" });
        const url = URL.createObjectURL(blob), a = document.createElement("a");
        a.href = url; a.download = "copilot-" + month.month + "-" + name + ".csv"; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
      }
      button(t.result, () => download(rows, "results"), actions).disabled = !!error.textContent;
      const allRows = () => selectRows(month, { ...state, threshold: "0", department: "", search: "", view: "all" });
      button(t.allCsv, () => download(allRows(), "all"), actions);
      button(t.departmentCsv, () => download(allRows().filter(r => !state.department || r.department === state.department), "department"), actions);
      const list = element("div"); list.className = "cp-results"; list.setAttribute("role", "list");
      if (!rows.length) element("p", t.empty, list);
      const limit = state.limit || 24;
      rows.slice(0, limit).forEach(r => {
        const card = element("article", undefined, list); card.setAttribute("role", "listitem");
        element("h3", r.displayName || r.upn, card); element("p", r.upn, card); element("p", `${t.department}: ${r.department || "—"}`, card);
        element("p", state.view === "mtd" ? `${t.observed}: ${r.observedCount === null ? t.unavailable : r.observedCount}` : `${t.count}: ${r.count === null ? t.unavailable : r.count}`, card);
        if (state.observed && state.view !== "mtd") element("p", `${t.observed}: ${r.observedCount === null ? t.unavailable : r.observedCount}`, card);
        element("p", `${t.known}: ${r.knownDays} / ${r.knownDays + r.unknownDays} · ${t.unknown}: ${r.unknownDays}`, card).className = "cp-muted";
      });
      if (rows.length > limit) {
        const more = element("div"); more.className = "cp-more";
        element("span", `${t.shown} ${limit} / ${rows.length} ${t.results}`, more);
        button(t.more, () => { state.limit = limit + 24; render(); }, more);
      }
      if (focus) { const n = root.querySelector("#" + prefix + focus.key); n.focus(); if (typeof focus.position === "number" && n.type !== "checkbox") n.setSelectionRange(focus.position, focus.position); }
    }
    render();
    return { dispose() { disposed = true; root.replaceChildren(); }, getState: () => ({ ...state }) };
  }
  const api = { validate, selectRows, csv, mount };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  global.CopilotMonthly = api;
})(typeof globalThis !== "undefined" ? globalThis : window);
