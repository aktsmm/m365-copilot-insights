#requires -Version 7.5
<#
.SYNOPSIS
公開済み契約の実測exportと独立合成デモを、明確な2入口に配置します。
.DESCRIPTION
固定SHA256で承認された公開用payloadだけを読み、private原本には接続しません。
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pocRoot = Split-Path $PSScriptRoot -Parent
$node = (Get-Command node -ErrorAction Stop).Source
$payloadPath = Join-Path $pocRoot 'tests\fixtures\public-measured-monthly.json'
$raw = (Get-Content -LiteralPath $payloadPath -Raw -Encoding utf8).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
$digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($raw))).ToLowerInvariant()
if ($digest -cne '17b7e9a8f912d8967b502beb83f9c0b35518b92a6db7710037616a69c0a7d293') {
    throw 'Measured public payload differs from the reviewed export.'
}
& $node (Join-Path $pocRoot 'scripts\Validate-CopilotPublicPayload.cjs') $payloadPath
if ($LASTEXITCODE -ne 0) { throw 'Measured public contract failed.' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$synthetic = & (Join-Path $PSScriptRoot 'Build-CopilotSyntheticPages.ps1') -OutputDirectory $output
$measured = & (Join-Path $PSScriptRoot 'Export-CopilotMonthlyDashboard.ps1') `
    -PayloadPath $payloadPath -OutputPath (Join-Path $output 'measured-monthly.html') -DataClass tenant -ShowObservedCounts
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $output 'measured-monthly.json'), $raw, $utf8)
$nav = '<nav aria-label="公開デモの切替" style="padding:1rem;background:var(--cp-surface);color:var(--cp-text);font-family:Segoe UI,Aptos,Calibri,sans-serif"><a style="color:var(--cp-link)" href="index.html">デモ一覧 / Demo home</a> | <a style="color:var(--cp-link)" href="measured-monthly.html">Diamond実測 / Measured demo environment</a> | <a style="color:var(--cp-link)" href="synthetic-monthly.html">完全合成 / Fully synthetic</a> | <a style="color:var(--cp-link)" href="architecture.html">仕組みとデータ元 / How it works</a></nav>'
$notice = '<aside style="padding:1rem;border:2px solid var(--cp-warning);background:var(--cp-surface);color:var(--cp-text);font-family:Segoe UI,Aptos,Calibri,sans-serif"><strong>Diamondデモ環境の実測値（アカウント・部門名は公開用表記）</strong><p>データ元: Microsoft Graph の Copilot 利用状況レポート（actions）とEntraのユーザー属性。<a style="color:var(--cp-link)" href="architecture.html#sources">詳細・原本リンク</a></p><p>これはactionsでありpromptsではありません。当月不完全のため確定回数は不明です。unknownはzeroではなく、不明を0に置き換えていません。観測回数は参考値であり、少利用判定には使用しません。</p><p>Measured values from the Diamond demo environment; account and department names use public-only labels. Actions are not prompts. The current month is incomplete; unknown is not zero. Observed counts are reference only, never confirmed low usage.</p></aside>'
$measuredPath = Join-Path $output 'measured-monthly.html'
$html = Get-Content -LiteralPath $measuredPath -Raw -Encoding utf8
$initialView = '<script>(() => { const view = document.querySelector(''select[id$="-view"]''); if (view) { view.value = "unknown"; view.dispatchEvent(new Event("change", { bubbles: true })); } })();</script>'
$html = $html.Replace('<main id="dashboard">', "$nav$notice<main id=`"dashboard`">").Replace('</body>', "$initialView</body>")
[IO.File]::WriteAllText($measuredPath, $html, $utf8)
$syntheticPath = Join-Path $output 'synthetic-monthly.html'
$html = Get-Content -LiteralPath $syntheticPath -Raw -Encoding utf8
$html = [regex]::Replace($html, '<nav aria-label="合成デモの表示切替".*?</nav>', '', [Text.RegularExpressions.RegexOptions]::Singleline)
$syntheticNotice = '<aside style="padding:1rem;background:var(--cp-surface);color:var(--cp-text);font-family:Segoe UI,Aptos,Calibri,sans-serif"><strong>完全合成データ・実績ではありません / Fully synthetic, not actual usage</strong><p>データ元: リポジトリ内の合成フィクスチャ（<a style="color:var(--cp-link)" href="https://github.com/aktsmm/m365-copilot-insights/tree/main/exports/synthetic">exports/synthetic</a>）。<a style="color:var(--cp-link)" href="architecture.html#sources">詳細</a></p></aside>'
[IO.File]::WriteAllText($syntheticPath, $html.Replace('<main id="dashboard">', "$nav$syntheticNotice<main id=`"dashboard`">"), $utf8)
$indexPath = Join-Path $output 'index.html'
$periodPath = Join-Path $output 'reporting-period.html'
$periodHtml = (Get-Content -LiteralPath $indexPath -Raw -Encoding utf8).Replace('href="index.html">従来の期間集計', 'href="reporting-period.html">従来の期間集計')
[IO.File]::WriteAllText($periodPath, $periodHtml, $utf8)
$css = Get-Content -LiteralPath (Join-Path $pocRoot 'monthly-ui\dashboard.css') -Raw -Encoding utf8
$archPath = Join-Path $output 'architecture.html'
$sp = 'https://diax14120418.sharepoint.com/sites/pocv-copilot-usage-20261028'
$archBody = @"
<main class="cp-monthly" style="max-width:62rem;margin:auto;line-height:1.7">
<h1>仕組みとデータ元 / How it works</h1>
<p><a href="index.html">&larr; 公開デモ一覧</a></p>
<h2>全体の流れ</h2>
<ol>
<li><b>取得</b>: 非公開のGitHub Actionsが、OIDC連携でMicrosoft Graphの Copilot 利用状況レポートとEntraのユーザー一覧（部門）を取得します。</li>
<li><b>匿名化・検証</b>: 非公開側で氏名・アカウント・部署名を公開用ラベルに置換し、契約（スキーマ）と固定ハッシュで検証します。unknown（欠測）は0に置き換えません。</li>
<li><b>公開</b>: 検証済みの公開用JSONだけから静的HTML（このPages）をビルドします。秘密情報・元ID・内部URLは含みません。</li>
<li><b>社内閲覧</b>: 同じ集計をSharePoint上のSPFx Webパーツ（日本語既定）とCSVダウンロードで提供します。</li>
<li><b>解説</b>: Agentic Workflow（GitHub Copilot CLI）が集計値だけを読み、要約コメントをIssueに書き出します（今回の実行は変更なし）。</li>
</ol>
<h2 id="sources">データ元と原本リンク</h2>
<table><thead><tr><th>#</th><th>画面・成果物</th><th>データ元</th><th>原本・参照</th></tr></thead><tbody>
<tr><td>1</td><td><a href="measured-monthly.html">Diamond実測</a></td><td>Graph Copilot利用状況レポート（actions）＋Entraユーザー（部門）。当月は月初来の参考値</td><td><a href="measured-monthly.json">公開用JSON</a> / <a href="https://learn.microsoft.com/ja-jp/graph/api/reportroot-getmicrosoft365copilotusageuserdetail">Graph API</a> / <a href="https://learn.microsoft.com/ja-jp/graph/api/user-list">ユーザー一覧API</a></td></tr>
<tr><td>2</td><td><a href="synthetic-monthly.html">完全合成</a></td><td>合成フィクスチャ（実績ではない）</td><td><a href="https://github.com/aktsmm/m365-copilot-insights/tree/main/exports/synthetic">exports/synthetic</a></td></tr>
<tr><td>3</td><td><a href="reporting-period.html">従来の期間集計</a></td><td>合成データ（期間集計・prompts）</td><td><a href="manifest.json">manifest.json</a></td></tr>
<tr><td>4</td><td>SharePoint（社内・要ログイン）</td><td>非公開側の検証済み集計（部門別）</td><td><a href="$sp">専用サイト</a>（権限のあるユーザーのみ）</td></tr>
<tr><td>5</td><td>CSV</td><td>各ダッシュボード内の「CSVダウンロード」で、表示中の絞り込み結果を出力</td><td>各ページ内</td></tr>
</tbody></table>
<h2>リンク集</h2>
<ul>
<li><a href="$sp">SharePoint専用サイト（要ログイン）</a></li>
<li><a href="https://github.com/aktsmm/m365-copilot-insights/blob/main/docs/setup-guide.md">セットアップガイド（必要な権限）</a></li>
<li><a href="https://github.com/aktsmm/m365-copilot-insights/blob/main/docs/operations-notes.md">運用メモ</a></li>
<li><a href="https://github.com/aktsmm/m365-copilot-insights">GitHubリポジトリ</a></li>
<li><a href="https://learn.microsoft.com/ja-jp/sharepoint/dev/spfx/sharepoint-framework-overview">SharePoint Framework（SPFx）</a></li>
</ul>
<p>注意: 実測は actions であり prompts ではありません。月途中は確定できず「不明」と表示します。</p>
</main>
"@
$archHtml = "<!doctype html><html lang=`"ja`"><head><meta charset=`"UTF-8`"><meta name=`"viewport`" content=`"width=device-width,initial-scale=1`"><title>仕組みとデータ元</title><script>document.documentElement.setAttribute('data-theme', new URLSearchParams(location.search).get('scoutTheme') || 'dark');</script><style>$css`nbody{margin:0;padding:1rem;background:var(--cp-bg);color:var(--cp-text)}a{color:var(--cp-link)}table{border-collapse:collapse;width:100%}th,td{border:1px solid var(--cp-border);padding:.4rem .6rem;text-align:left;vertical-align:top}th{background:var(--cp-surface)}li{margin:.3rem 0}</style></head><body>$archBody</body></html>"
[IO.File]::WriteAllText($archPath, $archHtml, $utf8)
$landing = @"
<!doctype html>
<html lang="ja"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Copilot 利用状況・公開デモ</title>
<script>
(() => {
  const param = new URLSearchParams(window.location.search).get("scoutTheme");
  const theme = param || "dark";
  document.documentElement.setAttribute("data-theme", theme);
})();
</script>
<style>$css
body { margin:0; background:var(--cp-bg); color:var(--cp-text); }
a { color:var(--cp-link); }
main { max-width:76rem; margin:auto; } .hero { padding:1rem 0 .5rem; border-bottom:1px solid var(--cp-border); } .hero h1 { margin:.25rem 0; font-size:1.6rem; } .cp-monthly .card h2 { margin:0 0 .5rem; font-size:1.1rem; } .cp-monthly .card { padding:1rem 1.25rem; background:var(--cp-surface); border:1px solid var(--cp-border); border-top:3px solid var(--cp-accent); border-radius:8px; } .cp-monthly .card.syn { border-top-color:var(--cp-warning); } .tag { display:inline-block; padding:.05rem .5rem; border:1px solid var(--cp-border-strong); border-radius:999px; color:var(--cp-text-soft); font-size:.72rem; margin-right:.35rem; } .links { margin-top:1rem; display:flex; flex-wrap:wrap; gap:1.25rem; }
</style></head>
<body><main class="cp-monthly">
<h1>Copilot 利用状況・公開デモ / Public usage demos</h1>
<p>実測値と合成データを別画面で表示します。 / Measured and synthetic data are separate demos.</p>
<div class="cp-results">
<article class="card"><h2><a href="measured-monthly.html">1. Diamondデモ環境の実測値</a></h2>
<p>アカウント・部門名は公開用表記です。actionsでありpromptsではありません。当月不完全・unknownはzeroではありません。</p>
<p>Measured demo-environment actions. Public-only identity labels. Incomplete month: unknown is not zero.</p>
<p>「不明・欠測」または「全件」と「観測回数（参考）を表示」で、実取得の状態を確認できます。</p></article>
<article class="card syn"><h2><a href="synthetic-monthly.html">2. 完全合成・月次しきい値デモ</a></h2>
<p>完全合成データ・実績ではありません。日本語／English、5・10・15・30未満／任意整数、部門、不明の挙動を確認できます。</p>
<p>Fully synthetic, not actual usage. Demonstrates language switching, strict thresholds, department filters and unknown values.</p></article>
</div>
<div class="links"><a href="architecture.html"><b>仕組みとデータ元 / How it works</b></a><a href="https://diax14120418.sharepoint.com/sites/pocv-copilot-usage-20261028">SharePoint（要ログイン）</a><a href="reporting-period.html">従来の期間集計（完全合成） / Reporting-period summary (synthetic)</a><a href="https://github.com/aktsmm/m365-copilot-insights/blob/main/docs/setup-guide.md">セットアップガイド（必要な権限） / Setup guide</a><a href="https://github.com/aktsmm/m365-copilot-insights">GitHub</a></div>
<p>公開ページに秘密・元アカウントID・元UPN・元氏名・元部署名・管理ID・内部URLは含めません。配布後の公開データは匿名閲覧・再配布が可能です。</p>
</main></body></html>
"@
[IO.File]::WriteAllText($indexPath, $landing, $utf8)
$manifestPath = Join-Path $output 'manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
$manifest.dataClass = 'mixed-explicitly-separated'
$manifest.publicMeasuredExport = [ordered]@{
    dataClass = 'tenant'; publicPayloadSha256 = $digest
    htmlSha256 = (Get-FileHash -LiteralPath $measuredPath -Algorithm SHA256).Hash.ToLowerInvariant()
    identityPolicy = 'Public-only sequential account and department labels; no original mapping or source hash is published'
    metric = 'actions-not-prompts'; unknownIsZero = $false
}
$manifest.monthlyFixture.htmlSha256 = (Get-FileHash -LiteralPath $syntheticPath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest.files = @(Get-ChildItem -LiteralPath $output -File -Recurse | Where-Object { $_.FullName -ne $manifestPath } |
    Sort-Object FullName | ForEach-Object {
        [ordered]@{ path = [IO.Path]::GetRelativePath($output, $_.FullName).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
[IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 30) + "`n"), $utf8)
[pscustomobject]@{
    Status = 'success'; DistributionAllowed = $true; Entrances = @('measured-monthly.html', 'synthetic-monthly.html')
    MeasuredPayloadSha256 = $digest
    MeasuredHtmlSha256 = $manifest.publicMeasuredExport.htmlSha256
    SyntheticHtmlSha256 = $manifest.monthlyFixture.htmlSha256
    IndexSha256 = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
