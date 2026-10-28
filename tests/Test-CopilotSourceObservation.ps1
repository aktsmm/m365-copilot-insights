#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pocRoot = Split-Path $PSScriptRoot -Parent
$export = Join-Path $pocRoot 'scripts/Export-CopilotSourceObservation.ps1'
$work = Join-Path $PSScriptRoot ('.source-test-' + [guid]::NewGuid().ToString('N'))
$previousTemp = $env:RUNNER_TEMP
$script:Checks = 0
$script:Case = 0
function Assert($Condition, [string]$Message) {
    $script:Checks++
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}
function New-Summary {
    # Constructed test structure only; not evidence of live tenant collection.
    @{
        collectedAt = '2026-10-28T04:00:00.0000000Z'
        distributionAllowed = $false; rawDataUploaded = $false
        periodProbes = @(@{ period = 'D7'; status = 200; rows = 3 })
        sourceUsage = @{
            SourceRows = 3; KnownPromptRows = 2; UnknownPromptRows = 1; KnownPromptTotal = 15
            ReportRefreshDate = '2026-10-26'; ReportPeriod = '7'
            ObservationScope = 'source-only'; DistributionAllowed = $false
        }
        joinQuality = @{ sourceRows = 3; matchedUpnRows = 0; unmatchedUpnRows = 3; matchedWithoutDepartmentRows = 0; hex32IdentifierRows = 3 }
        sourceReportSha256 = 'a' * 64
    }
}
function Invoke-TestExport($Summary, [switch]$WhatIf) {
    $script:Case++
    $input = Join-Path $work "summary-$script:Case.json"
    [IO.File]::WriteAllText($input, ($Summary | ConvertTo-Json -Depth 15), [Text.UTF8Encoding]::new($false))
    & $export -SummaryPath $input -OutputDirectory (Join-Path $work "output-$script:Case") `
        -RunUrl 'https://github.com/aktsmm/m365-copilot-insights/actions/runs/123' -WhatIf:$WhatIf
}
function Reject($Summary, [string]$Message) {
    $failed = $false
    try { Invoke-TestExport $Summary | Out-Null } catch { $failed = $true }
    Assert $failed $Message
    Assert (-not (Test-Path -LiteralPath (Join-Path $work "output-$script:Case"))) 'Invalid summary writes nothing'
}
try {
    [void][IO.Directory]::CreateDirectory($work)
    $env:RUNNER_TEMP = $work
    foreach ($path in @($export, $PSCommandPath)) { [void][scriptblock]::Create((Get-Content -LiteralPath $path -Raw -Encoding UTF8)) }
    $first = Invoke-TestExport (New-Summary)
    $second = Invoke-TestExport (New-Summary)
    Assert ($first.Sha256 -ceq $second.Sha256) 'Deterministic output bytes'
    Assert ($first.Status -ceq 'source-only' -and -not $first.DistributionAllowed -and $first.SourceRows -eq 3) 'Return contract'
    $html = Get-Content -LiteralPath $first.HtmlPath -Raw -Encoding UTF8
    Assert ($html.Contains('<html lang="ja">') -and $html.Contains('実テナント取得元の全体観測')) 'Japanese first render'
    Assert ($html.Contains('部門別配信は未成立・未完了') -and $html.Contains('M365管理センターの画面ではありません')) 'Scope and non-admin-center disclaimer'
    Assert ($html.Contains('<td>15</td>') -and $html.Contains('<td>3</td>') -and $html.Contains('<td>2026-10-26</td>')) 'Only input aggregate values rendered'
    Assert ($html.Contains('部門向けの自動配信は停止中です。') -and -not $html.Contains('配布許可はありません')) 'Warning is scoped to automated department delivery'
    Assert ($html.Contains('この画面単体では取得元を独立検証しません。') -and
        $html.Contains('取得・テナント照合の実行証跡はリンク先の収集ジョブを参照してください。')) 'Renderer limitations do not negate collection-job evidence'
    Assert ($html.Contains('<p class="hint" data-ja="この生成画面はM365管理センター')) 'Admin-center disclaimer is a neutral note'
    Assert ($html.Contains('レポート行数</span></dt><dd>3</dd>') -and
        $html.Contains('判明プロンプト合計</span></dt><dd>15</dd>') -and
        $html.Contains('UPN照合（照合済み／全体）</span></dt><dd>0 / 3</dd>')) 'Three KPIs use validated input counts'
    Assert ($html.IndexOf('<dl class="metrics"') -lt $html.IndexOf('<section class="card"')) 'KPIs precede detailed table'
    Assert ($html.Contains('aria-pressed="true"') -and $html.Contains('data-language="en"') -and $html.Contains('document.documentElement.lang = language')) 'Accessible Japanese/English switch'
    Assert ($html.Contains('--cp-highlight:') -and $html.Contains('overflow-x: auto') -and $html.Contains(':focus-visible')) 'Shared theme, responsive table and focus'
    Assert ($html -notmatch 'fetch\s*\(|localStorage|<script[^>]+src|type="module"|<iframe') 'Offline static page'
    $csv = @(Import-Csv -LiteralPath $first.CsvPath -Encoding UTF8)
    $json = Get-Content -LiteralPath $first.JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($csv.Count -eq 1 -and $csv[0].'取得元レポート行数' -eq '3' -and
        $csv[0].'既知の送信プロンプト数合計' -eq '15') 'CSV reconciles with validated HTML source'
    Assert ($csv[0].'プロンプト数が不明の行数' -eq '1' -and $csv[0].'UPN未照合の行数' -eq '3') 'CSV keeps unknown and unmatched counts'
    Assert ($json.SourceRows -eq 3 -and $json.KnownPromptTotal -eq 15 -and
        $json.ReportPeriod -eq '7' -and -not $json.DistributionAllowed) 'Machine-readable JSON preserves source-only contract'
    Assert ($csv[0].'観測範囲' -eq '取得元全体のみ・部門配信停止中') 'CSV is not labeled as department delivery'
    foreach ($name in @('source-observation.csv', 'source-observation.json')) {
        Assert ((Get-FileHash (Join-Path $first.OutputDirectory $name)).Hash -eq
            (Get-FileHash (Join-Path $second.OutputDirectory $name)).Hash) 'CSV and JSON are deterministic'
    }
    $s = New-Summary
    $s['displayName'] = '<script>leak-identifier@example.invalid</script>'
    $s['department'] = 'private-department'
    $s.periodProbes[0]['errorCode'] = 'secret-token-untrusted'
    $s['extra'] = @{ name = '<img src=x onerror=alert(1)>' }
    $injected = Invoke-TestExport $s
    $safeHtml = Get-Content -LiteralPath $injected.HtmlPath -Raw -Encoding UTF8
    Assert ($safeHtml -notmatch 'leak-identifier|private-department|secret-token|<img') 'Unallowlisted strings never flow into HTML'
    Assert ($safeHtml -ceq $html) 'Unallowlisted fields do not affect output bytes'
    foreach ($name in @('source-observation.csv', 'source-observation.json')) {
        $text = Get-Content -LiteralPath (Join-Path $injected.OutputDirectory $name) -Raw -Encoding UTF8
        Assert ($text -notmatch 'leak-identifier|private-department|secret-token|<img') 'Unallowlisted fields never flow into CSV or JSON'
        Assert ((Get-FileHash (Join-Path $first.OutputDirectory $name)).Hash -eq
            (Get-FileHash (Join-Path $injected.OutputDirectory $name)).Hash) 'Unallowlisted fields do not affect CSV or JSON bytes'
    }
    $s = New-Summary; $s.sourceUsage.KnownPromptRows = 0; $s.sourceUsage.UnknownPromptRows = 3; $s.sourceUsage.KnownPromptTotal = $null
    $result = Invoke-TestExport $s
    Assert ((Get-Content -LiteralPath $result.HtmlPath -Raw -Encoding UTF8).Contains('不明（既知値なし）')) 'All unknown total stays unknown'
    Assert ((Get-Content -LiteralPath $result.HtmlPath -Raw -Encoding UTF8) -match '判明プロンプト合計</span></dt><dd><span[^>]+>不明（既知値なし）</span></dd>') 'Unknown KPI is not zero'
    Assert ((Import-Csv -LiteralPath $result.CsvPath -Encoding UTF8).'既知の送信プロンプト数合計' -eq '') 'Unknown CSV total is empty, not zero'
    Assert ($null -eq (Get-Content -LiteralPath $result.JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json).KnownPromptTotal) 'Unknown JSON total stays null'
    $s = New-Summary; $s.sourceUsage.KnownPromptTotal = 0
    $result = Invoke-TestExport $s
    Assert ((Get-Content -LiteralPath $result.HtmlPath -Raw -Encoding UTF8).Contains('<td>0</td>')) 'Known zero accepted'
    Assert ((Get-Content -LiteralPath $result.HtmlPath -Raw -Encoding UTF8).Contains('判明プロンプト合計</span></dt><dd>0</dd>')) 'Known zero KPI remains numeric zero'
    Assert ((Import-Csv -LiteralPath $result.CsvPath -Encoding UTF8).'既知の送信プロンプト数合計' -eq '0') 'Known CSV zero remains numeric zero'
    Invoke-TestExport (New-Summary) -WhatIf | Out-Null
    Assert (-not (Test-Path -LiteralPath (Join-Path $work "output-$script:Case"))) 'WhatIf writes nothing'
    foreach ($edit in @(
        { param($s) $s.sourceUsage.SourceRows = 4 },
        { param($s) $s.sourceUsage.KnownPromptRows = -1 },
        { param($s) $s.sourceUsage.KnownPromptRows = 1.5 },
        { param($s) $s.sourceUsage.SourceRows = [decimal]'9223372036854775808' },
        { param($s) $s.sourceUsage.KnownPromptTotal = $null },
        { param($s) $s.sourceUsage.KnownPromptTotal = -1 },
        { param($s) $s.sourceUsage.KnownPromptTotal = 1.5 },
        { param($s) $s.sourceUsage.KnownPromptTotal = [decimal]'18446744073709551615' },
        { param($s) $s.sourceUsage.KnownPromptTotal = '15' },
        { param($s) $s.sourceUsage.KnownPromptRows = 0; $s.sourceUsage.UnknownPromptRows = 3 },
        { param($s) $s.sourceUsage.ObservationScope = '<script>bad</script>' },
        { param($s) $s.sourceUsage.DistributionAllowed = $true },
        { param($s) $s.distributionAllowed = $true },
        { param($s) $s.rawDataUploaded = $true },
        { param($s) $s.distributionAllowed = 'false' },
        { param($s) $s.Remove('distributionAllowed') },
        { param($s) $s.joinQuality.sourceRows = 4 },
        { param($s) $s.joinQuality.unmatchedUpnRows = 2 },
        { param($s) $s.joinQuality.matchedWithoutDepartmentRows = 1 },
        { param($s) $s.joinQuality.hex32IdentifierRows = 4 },
        { param($s) $s.sourceReportSha256 = '<script>bad</script>' },
        { param($s) $s.periodProbes[0].status = 403 },
        { param($s) $s.periodProbes[0].rows = 2 },
        { param($s) $s.periodProbes = @($s.periodProbes[0], $s.periodProbes[0]) },
        { param($s) $s.sourceUsage.ReportPeriod = '28' },
        { param($s) $s.sourceUsage.ReportRefreshDate = 'invalid' },
        { param($s) $s.collectedAt = '<script>bad</script>' },
        { param($s) $s.collectedAt = '2026-10-20T00:00:00Z' }
    )) {
        $s = New-Summary; & $edit $s | Out-Null
        Reject $s 'Malformed or inconsistent summary rejected'
    }
    $summaryPath = Join-Path $work 'boundary.json'
    [IO.File]::WriteAllText($summaryPath, ((New-Summary) | ConvertTo-Json -Depth 15))
    foreach ($url in @('https://github.com/example/other-repository/actions/runs/123',
        'https://evil.invalid/actions/runs/123', 'https://github.com/aktsmm/m365-copilot-insights/actions/runs/123?x=1',
        'javascript:alert(1)', 'https://github.com/aktsmm/m365-copilot-insights/actions/runs/123/')) {
        $failed = $false
        try { & $export -SummaryPath $summaryPath -OutputDirectory (Join-Path $work 'bad-url') -RunUrl $url | Out-Null } catch { $failed = $true }
        Assert $failed 'Only fixed private repository run URL accepted'
    }
    foreach ($output in @((Join-Path $work 'exports\bad'), (Join-Path $pocRoot 'tests\forbidden'),
        "$work\safe\..\escape", $first.OutputDirectory)) {
        $failed = $false
        try { & $export -SummaryPath $summaryPath -OutputDirectory $output -RunUrl 'https://github.com/aktsmm/m365-copilot-insights/actions/runs/123' | Out-Null } catch { $failed = $true }
        Assert $failed 'Output boundary and absent-directory contract'
    }
    Write-Output "PASS: $script:Checks source observation assertions; constructed test structures only, not live tenant evidence."
}
finally {
    $env:RUNNER_TEMP = $previousTemp
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
