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
      (state.view === "all" || (state.view === "unknown" ? r.status === "unknown" :
        r.status === "known" && r.count !== null && r.count < Number(state.threshold))))
      .sort((a, b) => {
        const x = a.row, y = b.row;
        let order;
        if (state.sort === "count") order = x.count === null ? (y.count === null ? 0 : 1) : y.count === null ? -1 : x.count - y.count;
        else order = String(x[state.sort]).localeCompare(String(y[state.sort]), "ja");
        return order || a.index - b.index;
      }).map(x => x.row);
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
    ja: { title: "Copilot 月次利用状況", language: "English", month: "対象月", metric: "指標・ソース", department: "部門（集計時点）", search: "氏名 / UPN 検索", threshold: "しきい値（厳密に未満）", preset: "しきい値プリセット", view: "表示対象", low: "しきい値未満（確定値のみ）", unknown: "不明・欠測", all: "全件", sort: "並び順", count: "確定回数", displayName: "氏名", reset: "リセット", result: "結果 CSV", allCsv: "選択月・指標の全体 CSV", departmentCsv: "部門 CSV", source: "ソース", basis: "ソース日付基準", refresh: "レポート基準日", generated: "生成日時", complete: "完全月", partial: "取得不足・参考値", "in-progress": "当月途中・参考値", observed: "観測回数（参考のみ）", known: "既知", missing: "欠測日", empty: "該当する行がありません。", warning: "欠測・当月途中の回数は参考値です。少利用を確定できません。不明は0として扱いません。", download: "CSV / HTMLの持ち出し後には、SharePointのアクセス制御・取り消しは適用されません。", showObserved: "観測回数（参考）を表示", total: "母集団", results: "結果", unavailable: "不明", synthetic: "合成データ（実績ではありません）", tenant: "テナントデータ" },
    en: { title: "Copilot monthly usage", language: "日本語", month: "Month", metric: "Metric / source", department: "Department (at aggregation)", search: "Name / UPN search", threshold: "Threshold (strictly less than)", preset: "Threshold presets", view: "View", low: "Below threshold (confirmed only)", unknown: "Unknown / missing", all: "All", sort: "Sort by", count: "Confirmed count", displayName: "Name", reset: "Reset", result: "Results CSV", allCsv: "All CSV (selected month / metric)", departmentCsv: "Department CSV", source: "Source", basis: "Source date basis", refresh: "Report refresh date", generated: "Generated at", complete: "Complete month", partial: "Partial / reference only", "in-progress": "In progress / reference only", observed: "Observed count (reference only)", known: "Known", missing: "Missing dates", empty: "No matching rows.", warning: "Incomplete / current-month counts are reference only, not confirmed low usage. Unknown is never zero.", download: "Downloaded CSV / HTML is no longer protected or revocable by SharePoint access controls.", showObserved: "Show observed counts (reference)", total: "Population", results: "Results", unavailable: "Unknown", synthetic: "Synthetic data (not actual usage)", tenant: "Tenant data" }
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
        n.addEventListener(values ? "change" : "input", () => { state[key] = n.value; if (action) action(); render({ key, position: n.selectionStart }); });
        return n;
      }
      const monthNames = [...new Set(payload.months.map(m => m.month))].sort().reverse();
      control("month", t.month, monthNames.map(m => [m, m]), () => { state.key = ""; state.department = ""; });
      const choices = payload.months.map((m, i) => ({ m, i })).filter(x => x.m.month === state.month);
      if (!choices.some(x => String(x.i) === state.key)) state.key = String(choices[0].i);
      const month = payload.months[Number(state.key)];
      control("key", t.metric, choices.map(x => [String(x.i), (state.language === "ja" ? x.m.metricLabelJa : x.m.metricLabelEn) + " / " + x.m.source]), () => { state.department = ""; });
      control("department", t.department, [["", t.all], ...[...new Set(month.rows.map(r => r.department))].sort().map(d => [d, d || "—"])]);
      control("search", t.search);
      const threshold = control("threshold", t.threshold);
      const presets = element("div", undefined, filters);
      presets.setAttribute("role", "group"); presets.setAttribute("aria-label", t.preset);
      [5, 10, 15, 30].forEach(n => button(String(n), () => { state.threshold = String(n); render(); }, presets));
      control("view", t.view, [["low", t.low], ["unknown", t.unknown], ["all", t.all]]);
      control("sort", t.sort, [["count", t.count], ["displayName", t.displayName], ["department", t.department]]);
      const observedLabel = element("label", t.showObserved, filters);
      const observed = element("input", undefined, observedLabel); observed.type = "checkbox"; observed.checked = state.observed;
      observed.addEventListener("change", () => { state.observed = observed.checked; render(); });
      button(t.reset, () => { Object.assign(state, { month: payload.months[0].month, key: "", department: "", search: "", threshold: "5", view: "low", sort: "count", observed: !!(options && options.showObservedCounts) }); render(); });
      const metadata = element("dl");
      [[t.month, month.month], [t.source, month.source], [t.basis, month.dateBasis], [t.refresh, month.reportRefreshDate], [t.generated, payload.generatedAt],
        [state.language === "ja" ? "完全性" : "Completeness", t[month.coverage.status]],
        [state.language === "ja" ? "取得日 / 期待日" : "Available / expected dates", `${month.coverage.availableDates.length} / ${month.coverage.expectedDates.length}`],
        [t.missing, month.coverage.missingDates.join(", ") || "—"]].forEach(([k, v]) => { element("dt", k, metadata); element("dd", v, metadata); });
      if (month.coverage.status !== "complete") { const warning = element("p", t.warning); warning.className = "cp-warning"; }
      element("p", t.download).className = "cp-muted";
      const error = element("p"); error.id = prefix + "error"; error.setAttribute("role", "alert");
      let rows = [];
      try { rows = selectRows(month, state); threshold.removeAttribute("aria-invalid"); }
      catch (e) { error.textContent = e.message; threshold.setAttribute("aria-invalid", "true"); threshold.setAttribute("aria-describedby", error.id); }
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
      rows.forEach(r => {
        const card = element("article", undefined, list); card.setAttribute("role", "listitem");
        element("h3", r.displayName || r.upn, card); element("p", r.upn, card); element("p", `${t.department}: ${r.department || "—"}`, card);
        element("p", `${t.count}: ${r.count === null ? t.unavailable : r.count}`, card);
        if (state.observed) element("p", `${t.observed}: ${r.observedCount === null ? t.unavailable : r.observedCount}`, card);
        element("p", `${t.known}: ${r.knownDays} / ${r.knownDays + r.unknownDays} · ${t.unknown}: ${r.unknownDays}`, card).className = "cp-muted";
      });
      if (focus) { const n = root.querySelector("#" + prefix + focus.key); n.focus(); if (typeof focus.position === "number" && n.type !== "checkbox") n.setSelectionRange(focus.position, focus.position); }
    }
    render();
    return { dispose() { disposed = true; root.replaceChildren(); }, getState: () => ({ ...state }) };
  }
  const api = { validate, selectRows, csv, mount };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  global.CopilotMonthly = api;
})(typeof globalThis !== "undefined" ? globalThis : window);
