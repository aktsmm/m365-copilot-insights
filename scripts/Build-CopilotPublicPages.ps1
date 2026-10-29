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
if ($digest -cne 'fcb8cd64dfb5c763758ffe0b76189b82a9c660c613660f63fe931e5194d5b5a7') {
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
$nav = '<nav aria-label="公開デモの切替" style="padding:1rem;background:var(--cp-surface);color:var(--cp-text);font-family:Segoe UI,Aptos,Calibri,sans-serif"><a style="color:var(--cp-link)" href="index.html">Diamond実測（トップ） / Measured home</a> | <a style="color:var(--cp-link)" href="synthetic-monthly.html">完全合成デモ / Fully synthetic demo</a> | <a style="color:var(--cp-link)" href="reporting-period.html">従来の期間集計（合成） / Period summary</a> | <a style="color:var(--cp-link)" href="https://diax14120418.sharepoint.com/sites/pocv-copilot-usage-20261028">SharePoint（要ログイン）</a> | <a style="color:var(--cp-link)" href="https://github.com/aktsmm/m365-copilot-insights/blob/main/docs/setup-guide.md">セットアップ・必要権限</a> | <a style="color:var(--cp-link)" href="https://github.com/aktsmm/m365-copilot-insights">GitHub</a> | <a style="color:var(--cp-link)" href="architecture.html">仕組みとデータ元 / How it works</a> | <a style="color:var(--cp-link)" href="architecture.html#portal-map">M365/Viva画面との対応</a></nav>'
function Set-NavCurrent([string]$Nav, [string]$Href) {
    $plain = '<a style="color:var(--cp-link)" href="' + $Href + '">'
    $current = '<a aria-current="page" style="color:var(--cp-text);font-weight:700;text-decoration:none;border-bottom:2px solid var(--cp-warning)" href="' + $Href + '">'
    $Nav.Replace($plain, $current)
}
$notice = '<aside style="padding:1rem;border:2px solid var(--cp-warning);background:var(--cp-surface);color:var(--cp-text);font-family:Segoe UI,Aptos,Calibri,sans-serif"><strong>Diamondデモ環境の実測値（氏名・アカウントは * で一部伏せ字、部門名は実データ）</strong><p>データ元: Microsoft Graph の Copilot 利用状況レポート（actions）とEntraのユーザー属性。<a style="color:var(--cp-link)" href="architecture.html#sources">詳細・原本リンク</a></p><p>これはactionsでありpromptsではありません。当月不完全のため確定回数は不明です。unknownはzeroではなく、不明を0に置き換えていません。観測回数は参考値であり、少利用判定には使用しません。</p><p>Measured values from the Diamond demo environment; names and accounts are partially masked with *, department names are real. Actions are not prompts. The current month is incomplete; unknown is not zero. Observed counts are reference only, never confirmed low usage.</p></aside>'
$measuredPath = Join-Path $output 'measured-monthly.html'
$html = Get-Content -LiteralPath $measuredPath -Raw -Encoding utf8
$initialView = '<script>(() => { const view = document.querySelector(''select[id$="-view"]''); if (view) { view.value = "unknown"; view.dispatchEvent(new Event("change", { bubbles: true })); } })();</script>'
$html = $html.Replace('<main id="dashboard">', "$(Set-NavCurrent $nav 'index.html')$notice<main id=`"dashboard`">").Replace('</body>', "$initialView</body>")
[IO.File]::WriteAllText($measuredPath, $html, $utf8)
$syntheticPath = Join-Path $output 'synthetic-monthly.html'
$html = Get-Content -LiteralPath $syntheticPath -Raw -Encoding utf8
$html = [regex]::Replace($html, '<nav aria-label="合成デモの表示切替".*?</nav>', '', [Text.RegularExpressions.RegexOptions]::Singleline)
$syntheticNotice = '<aside style="padding:1rem;background:var(--cp-surface);color:var(--cp-text);font-family:Segoe UI,Aptos,Calibri,sans-serif"><strong>完全合成データ・実績ではありません / Fully synthetic, not actual usage</strong><p>データ元: リポジトリ内の合成フィクスチャ（<a style="color:var(--cp-link)" href="https://github.com/aktsmm/m365-copilot-insights/tree/main/exports/synthetic">exports/synthetic</a>）。<a style="color:var(--cp-link)" href="architecture.html#sources">詳細</a></p></aside>'
[IO.File]::WriteAllText($syntheticPath, $html.Replace('<main id="dashboard">', "$(Set-NavCurrent $nav 'synthetic-monthly.html')$syntheticNotice<main id=`"dashboard`">"), $utf8)
$indexPath = Join-Path $output 'index.html'
$periodPath = Join-Path $output 'reporting-period.html'
$periodHtml = (Get-Content -LiteralPath $indexPath -Raw -Encoding utf8).Replace('href="index.html">従来の期間集計', 'href="reporting-period.html">従来の期間集計')
$periodNotice = '<aside style="padding:1rem;background:var(--cp-surface);color:var(--cp-text);font-family:Segoe UI,Aptos,Calibri,sans-serif"><strong>完全合成データ・実績ではありません / Fully synthetic, not actual usage</strong></aside>'
$periodHtml = [regex]::Replace($periodHtml, '<nav aria-label="合成デモの表示切替".*?</nav>', [Text.RegularExpressions.MatchEvaluator]{ param($m) (Set-NavCurrent $nav 'reporting-period.html') + $periodNotice }, [Text.RegularExpressions.RegexOptions]::Singleline)
[IO.File]::WriteAllText($periodPath, $periodHtml, $utf8)
$css = Get-Content -LiteralPath (Join-Path $pocRoot 'monthly-ui\dashboard.css') -Raw -Encoding utf8
$archPath = Join-Path $output 'architecture.html'
$sp = 'https://diax14120418.sharepoint.com/sites/pocv-copilot-usage-20261028'
$archBody = @"
<main class="cp-monthly" style="max-width:62rem;margin:auto;line-height:1.7">
<h1>仕組みとデータ元 / How it works</h1>
<p><a href="index.html">&larr; トップ（Diamond実測）</a></p>
<h2>全体の流れ</h2>
<ol>
<li><b>取得</b>: 非公開のGitHub Actionsが、OIDC連携でMicrosoft Graphの Copilot 利用状況レポートとEntraのユーザー一覧（部門）を取得します。</li>
<li><b>匿名化・検証</b>: 非公開側で氏名・UPNを * で一部伏せ字にし（部署名は実データ）、GUID・ドメイン・URLを除いたうえで、契約（スキーマ）と固定ハッシュで検証します。unknown（欠測）は0に置き換えません。</li>
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
<h2 id="portal-map">M365 / Viva Insights の画面との対応</h2>
<table><thead><tr><th>#</th><th>見ている画面</th><th>取得方式</th><th>状態</th></tr></thead><tbody>
<tr><td>1</td><td>M365 管理センター &gt; レポート &gt; Microsoft 365 Copilot</td><td>Graph Copilot利用状況レポート（v1.0 CSV）をGitHub ActionsがOIDCで無人取得</td><td>自動取得済み</td></tr>
<tr><td>2</td><td>同 日別</td><td>Graph beta 日別（最新更新日の7日前から）を蓄積</td><td>窓外は復元不可</td></tr>
<tr><td>3</td><td>部門（Entraユーザー属性）</td><td>Graph users（department）をUPNで突合</td><td>自動取得済み</td></tr>
<tr><td>4</td><td>Viva Insights Copilotダッシュボード</td><td>人がUIで操作する「データのエクスポート」CSVのみ。無人APIは未確認</td><td>ブラウザ操作（CDP）で自動取得に成功。無人化は未達</td></tr>
<tr><td>5</td><td>Viva Insights 高度分析（Analysis results）</td><td>Power BI / Fabric コネクタ（Partition ID・Query ID必要）</td><td>対応中（機能アクセスポリシーを作成済み・反映待ち。分析メニューが出れば接続）</td></tr>
</tbody></table>
<p>詳細と公式リンク: <a href="https://github.com/aktsmm/m365-copilot-insights/blob/main/docs/data-sources.md">画面ごとのデータ取得方式（docs/data-sources.md）</a></p>
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
[IO.File]::WriteAllText($indexPath, (Get-Content -LiteralPath $measuredPath -Raw -Encoding utf8), $utf8)
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
