#requires -Version 7.5
<#
.SYNOPSIS
公開済み契約の実測exportと独立合成デモを、明確な2入口に配置します。
.DESCRIPTION
固定SHA256で承認された公開用payloadだけを読み、private原本には接続しません。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$CommentaryPath,
    [string]$CommentaryRunId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pocRoot = Split-Path $PSScriptRoot -Parent
$node = (Get-Command node -ErrorAction Stop).Source
$payloadPath = Join-Path $pocRoot 'tests\fixtures\public-measured-monthly.json'
$raw = (Get-Content -LiteralPath $payloadPath -Raw -Encoding utf8).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
$digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($raw))).ToLowerInvariant()
if ($digest -cne '8aa414ef5cc94881aa2a60bf08172e56aafaffe0f302f979e967626b96b243be') {
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
$nav = '<style>.cp-sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}.cp-skip{position:absolute;left:-999px;top:0}.cp-skip:focus{left:8px;top:8px;z-index:10;padding:.5rem 1rem;background:var(--cp-surface);color:var(--cp-text);border:2px solid var(--cp-warning)}</style><a class="cp-skip" href="#dashboard">メインへスキップ / Skip to main</a><h1 class="cp-sr">Copilot 月次利用状況 / Copilot monthly usage</h1><nav aria-label="公開デモの切替" style="padding:1rem;background:var(--cp-surface);color:var(--cp-text);font-family:Segoe UI,Aptos,Calibri,sans-serif"><a style="color:var(--cp-link)" href="index.html">Diamond実測（トップ） / Measured home</a> | <a style="color:var(--cp-link)" href="synthetic-monthly.html">完全合成デモ / Fully synthetic demo</a> | <a style="color:var(--cp-link)" href="https://diax14120418.sharepoint.com/sites/pocv-copilot-usage-20261028">SharePoint（要ログイン）</a> | <a style="color:var(--cp-link)" href="https://github.com/aktsmm/m365-copilot-insights/blob/main/docs/setup-guide.md">セットアップ・必要権限</a> | <a style="color:var(--cp-link)" href="https://github.com/aktsmm/m365-copilot-insights">GitHub</a> | <a style="color:var(--cp-link)" href="architecture.html">仕組みとデータ元 / How it works</a> | <a style="color:var(--cp-link)" href="architecture.html#portal-map">M365/Viva画面との対応</a></nav>'
function Set-NavCurrent([string]$Nav, [string]$Href) {
    $plain = '<a style="color:var(--cp-link)" href="' + $Href + '">'
    $current = '<a aria-current="page" style="color:var(--cp-text);font-weight:700;text-decoration:none;border-bottom:2px solid var(--cp-warning)" href="' + $Href + '">'
    $Nav.Replace($plain, $current)
}
$notice = @'
<aside style="padding:1rem;border:2px solid var(--cp-warning);background:var(--cp-surface);color:var(--cp-text);font-family:Segoe UI,Aptos,Calibri,sans-serif">
<strong>Diamondデモ環境の実測値（架空のデモ人物の氏名・部門名を表示、アカウントはドメインのみ非公開）</strong>
<p>データ元: Microsoft Graph の日別 Copilot 利用状況レポートと Entra ユーザー属性。<a style="color:var(--cp-link)" href="architecture.html#sources">詳細・原本リンク</a></p>
<p><b>Copilotアクション数</b>は各アプリでの Copilot 操作を表す指標、<b>Copilotプロンプト数</b>は Copilot に送信した質問の指標です。厳密な換算関係や大小関係は確認できていないため、別系列で表示し、足し合わせません。個別操作が必ず一回に数えられるとは断定しません。</p>
<details open><summary><b>データの出どころ（凡例） / Where each item comes from</b></summary>
<table style="border-collapse:collapse;margin:.5rem 0;font-size:.95em"><thead><tr><th>#</th><th>画面の項目</th><th>どこから取った情報か</th></tr></thead><tbody>
<tr><td>1</td><td>氏名・UPN・部門</td><td>Microsoft Entra のユーザー情報（Graph users）。UPN はドメイン部分を非公開、部門は取得時点の値</td></tr>
<tr><td>2</td><td>アクション数の観測回数</td><td>Graph beta 日別レポートの JSON 応答 allAppsCopilotActionCount を、取得できた日だけ合算</td></tr>
<tr><td>3</td><td>プロンプト数の観測回数</td><td>同じ日別 API の CSV 応答 Prompts submitted for All Apps を、取得できた日だけ合算。ブラウザなしで直接取得</td></tr>
<tr><td>4</td><td>確定回数</td><td>月が終了し、全日分を取得した場合のみ表示。それまでは不明（ゼロではない）</td></tr>
<tr><td>5</td><td>取得日・欠測日</td><td>GitHub Actions が蓄積した日別履歴。取得窓外・HTTP 504 などの失敗日は欠測</td></tr>
<tr><td>6</td><td>レポート基準日</td><td>Graph の Report Refresh Date。今日の利用状況とは限らない</td></tr>
<tr><td>7</td><td>生成日時</td><td>非公開処理側でこの集計を作った時刻（UTC）</td></tr>
<tr><td>8</td><td>このページに含まない値</td><td>Viva Insights、Purview 監査ログ、管理センターのエージェント一覧、メッセージセンターの通知。<a style="color:var(--cp-link)" href="architecture.html#portal-map">別の取得口と自動化状況</a></td></tr>
</tbody></table></details>
<p>公開ページは承認済みスナップショットです。定期収集の結果がそのまま自動公開されるわけではありません。unknown は zero ではなく、観測回数を少利用の確定判定に使いません。<a style="color:var(--cp-link)" href="architecture.html">できること・できないこと</a></p>
</aside>
'@
$measuredPath = Join-Path $output 'measured-monthly.html'
$html = Get-Content -LiteralPath $measuredPath -Raw -Encoding utf8
$commentaryArgs = @('render', $payloadPath, (Join-Path $output 'commentary-section.html'))
if ($CommentaryPath) { $commentaryArgs += @($CommentaryPath, $CommentaryRunId) }
& $node (Join-Path $PSScriptRoot 'Copilot.Commentary.cjs') @commentaryArgs
if ($LASTEXITCODE -ne 0) { throw 'AI commentary contract failed; refusing publication.' }
$commentarySection = Get-Content -LiteralPath (Join-Path $output 'commentary-section.html') -Raw -Encoding utf8
$initialView = '<script>(() => { const view = document.querySelector(''select[id$="-view"]''); if (view) { view.value = "unknown"; view.dispatchEvent(new Event("change", { bubbles: true })); } })();</script>'
$html = $html.Replace('<main id="dashboard">', "$(Set-NavCurrent $nav 'index.html')$notice$commentarySection<main id=`"dashboard`">").Replace('</body>', "$initialView</body>")
[IO.File]::WriteAllText($measuredPath, $html, $utf8)
$syntheticPath = Join-Path $output 'synthetic-monthly.html'
$html = Get-Content -LiteralPath $syntheticPath -Raw -Encoding utf8
$html = [regex]::Replace($html, '<nav aria-label="合成デモの表示切替".*?</nav>', '', [Text.RegularExpressions.RegexOptions]::Singleline)
$syntheticNotice = '<aside style="padding:1rem;background:var(--cp-surface);color:var(--cp-text);font-family:Segoe UI,Aptos,Calibri,sans-serif"><strong>完全合成データ・実績ではありません / Fully synthetic, not actual usage</strong><p>データ元: リポジトリ内の合成フィクスチャ（<a style="color:var(--cp-link)" href="https://github.com/aktsmm/m365-copilot-insights/tree/main/exports/synthetic">exports/synthetic</a>）。<a style="color:var(--cp-link)" href="architecture.html#sources">詳細</a></p></aside>'
[IO.File]::WriteAllText($syntheticPath, $html.Replace('<main id="dashboard">', "$(Set-NavCurrent $nav 'synthetic-monthly.html')$syntheticNotice<main id=`"dashboard`">"), $utf8)
$indexPath = Join-Path $output 'index.html'
$css = Get-Content -LiteralPath (Join-Path $pocRoot 'monthly-ui\dashboard.css') -Raw -Encoding utf8
$archPath = Join-Path $output 'architecture.html'
$sp = 'https://diax14120418.sharepoint.com/sites/pocv-copilot-usage-20261028'
$archBody = @"
<main class="cp-monthly" style="max-width:62rem;margin:auto;line-height:1.7">
<h1>仕組みとデータ元 / How it works</h1>
<p><a href="index.html">&larr; トップ（Diamond実測）</a></p>
<h2>全体の流れ</h2>
<ol>
<li><b>取得</b>: 公開リポジトリのGitHub Actionsが、OIDC連携でMicrosoft Graphの Copilot 利用状況レポートとEntraのユーザー一覧（部門）を取得します。処理データとSharePointの保存先は非公開で、ログには許可された状態情報だけを出します。</li>
<li><b>匿名化・検証</b>: 非公開側でUPNのドメインを隠し（氏名・部署名は架空の人物の実データ）、GUID・ドメイン・URLを除いたうえで、契約（スキーマ）と固定ハッシュで検証します。unknown（欠測）は0に置き換えません。</li>
<li><b>公開</b>: 検証済みの公開用JSONから静的HTMLをビルドします。秘密情報・元IDは除去し、架空のデモ人物の氏名と部署名は公開します。SharePointリンクは要認証で、リンクによる権限付与はありません。</li>
<li><b>社内閲覧</b>: 同じ集計をSharePoint上のSPFx Webパーツ（日本語既定）とCSVダウンロードで提供します。</li>
<li><b>解説</b>: 手動起動のMeasured aggregate commentaryが、公開承認済みデータの部門別集計だけを読み、AI解説JSONをActions artifactへ出します。成功するとPagesが自動起動し、集計の識別子・出力契約を検査してトップページに掲載します。未生成時はその旨を表示し、古いデータ向けの解説は拒否します。</li>
<li><b>障害記録</b>: 月次収集・監査集計の失敗やタイムアウトでIssueを自動作成・追記します。ジョブ名・ステップ名・実行URLだけを記録し、ログ本文の収集やAIによる原因確定・修復はしません。</li>
</ol>
<h2 id="sources">データ元と原本リンク</h2>
<table><thead><tr><th>#</th><th>画面・成果物</th><th>データ元</th><th>原本・参照</th></tr></thead><tbody>
<tr><td>1</td><td><a href="measured-monthly.html">Diamond実測</a></td><td>Graph Copilot利用状況レポート（日別: アクション数／プロンプト数）＋Entraユーザー（部門）。欠測のある参考値</td><td><a href="measured-monthly.json">公開用JSON</a> / <a href="https://learn.microsoft.com/ja-jp/microsoft-365/copilot/extensibility/api/admin-settings/reports/copilotreportroot-getmicrosoft365copilotusageuserdetailbydate">Graph 日別 API（beta）</a> / <a href="https://learn.microsoft.com/ja-jp/graph/api/user-list">ユーザー一覧API</a></td></tr>
<tr><td>2</td><td><a href="synthetic-monthly.html">完全合成</a></td><td>合成フィクスチャ（実績ではない）</td><td><a href="https://github.com/aktsmm/m365-copilot-insights/tree/main/exports/synthetic">exports/synthetic</a></td></tr>
<tr><td>3</td><td>SharePoint（社内・要ログイン）</td><td>非公開側の検証済み集計（部門別）</td><td><a href="$sp">専用サイト</a>（権限のあるユーザーのみ）</td></tr>
<tr><td>5</td><td>CSV</td><td>各ダッシュボード内の「CSVダウンロード」で、表示中の絞り込み結果を出力</td><td>各ページ内</td></tr>
</tbody></table>
<h2 id="portal-map">M365 / Viva Insights の画面との対応</h2>
<table><thead><tr><th>#</th><th>見ている画面</th><th>取得方式</th><th>状態</th></tr></thead><tbody>
<tr><td>1</td><td>M365 管理センター &gt; レポート &gt; Microsoft 365 Copilot</td><td>Graph Copilot利用状況レポート（v1.0 CSV）をGitHub ActionsがOIDCで無人取得</td><td>自動取得済み</td></tr>
<tr><td>2</td><td>同 日別</td><td>Graph beta 日別（最新更新日の7日前から）を蓄積</td><td>窓外は復元不可</td></tr>
<tr><td>3</td><td>部門（Entraユーザー属性）</td><td>Graph users（department）をUPNで突合</td><td>自動取得済み</td></tr>
<tr><td>4</td><td>Viva Insights Copilot / エージェントダッシュボード</td><td>ログイン済みブラウザからCSVをエクスポート。公開APIでの取得は確認できていない</td><td>画面操作で取得済み。GitHubだけの無人取得は未実装。この月次グラフには含めない</td></tr>
<tr><td>5</td><td>Viva Insights 高度分析（Analysis results）</td><td>公式にFabric Dataflow Gen2の定期更新とCopy jobがある（Partition ID・Query ID・容量が必要）</td><td>本テナントは11/4も分析結果ページに到達不可。未接続・追加費用未承認。クラウド自動化そのものが不可能という意味ではない</td></tr>
<tr><td>6</td><td>Purview監査ログ</td><td>Graph auditLog queriesを専用アプリのOIDCで取得し、日・アプリ・エージェント別に件数と利用者数を集計</td><td>毎日03:30 JSTに定期設定。公開ログはResearcher・Analyst・Planner Agentのみ表示し、他の名前は「その他」、未記録は別扱い。Vivaのセッション数とは別で、この月次グラフには含めない</td></tr>
<tr><td>7</td><td>M365メッセージセンター</td><td>本リポジトリには収集処理なし</td><td>取得・表示していない。Graphの利用レポートやVivaの別名ではない</td></tr>
</tbody></table>
<p>詳細と公式リンク: <a href="https://github.com/aktsmm/m365-copilot-insights/blob/main/docs/data-sources.md">画面ごとのデータ取得方式（docs/data-sources.md）</a></p>
<h2>自動化の境界</h2>
<p>定期のGraph収集・監査集計は通常のActionsスクリプトが担当します。AIは収集しません。実測データの公開は加工済みスナップショットの承認・差し替えが必要で、ライブから自動公開しません。AI解説はGitHub上で手動起動でき、成功後のPages配備だけ自動です。元の合成用synthetic-commentaryは別の手動・noopデモとして残しています。</p>
<h2>リンク集</h2>
<ul>
<li><a href="$sp">SharePoint専用サイト（要ログイン）</a></li>
<li><a href="https://github.com/aktsmm/m365-copilot-insights/blob/main/docs/setup-guide.md">セットアップガイド（必要な権限）</a></li>
<li><a href="https://github.com/aktsmm/m365-copilot-insights/blob/main/docs/operations-notes.md">運用メモ</a></li>
<li><a href="https://github.com/aktsmm/m365-copilot-insights">GitHubリポジトリ</a></li>
<li><a href="https://learn.microsoft.com/ja-jp/sharepoint/dev/spfx/sharepoint-framework-overview">SharePoint Framework（SPFx）</a></li>
</ul>
<p>注意: 実測はアクション数とプロンプト数の2系列で、互いに代用しません。月途中は確定できず「不明」と表示します。</p>
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
    identityPolicy = 'Approved fictional demo names and departments; sequential user IDs and hidden UPN domains'
    metrics = @('all-apps-actions', 'all-apps-prompts'); unknownIsZero = $false
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
