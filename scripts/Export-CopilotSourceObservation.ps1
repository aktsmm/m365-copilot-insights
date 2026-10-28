#requires -Version 7.0
<#
.SYNOPSIS
取得済みcollection-summary.jsonの許可された全体集計だけを非公開HTMLにします。
.DESCRIPTION
取得・認証・部門照合・配信を実行しません。出力先は未作成の.local/RUNNER_TEMP配下のみ。
既存dashboard.htmlのテーマと言語切替を再利用します。生成結果は実テナント成功の判定を拡張しません。
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SummaryPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$RunUrl
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot 'Copilot.Data.psm1') -Force -PassThru
if ($RunUrl -cnotmatch '^https://github\.com/aktsmm/m365-copilot-insights/actions/runs/[1-9][0-9]*$') {
    throw 'RunUrl must identify the fixed private repository Actions run.'
}
$output = & $module { param($path) Assert-OutputPath $path 'tenant' } $OutputDirectory
if (Test-Path -LiteralPath $output) { throw 'OutputDirectory must be absent.' }
if (-not (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) { throw 'SummaryPath does not exist.' }
$jsonOptions = @{ AsHashtable = $true }
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions.DateKind = 'String' }
$summary = Get-Content -LiteralPath $SummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json @jsonOptions
function Require-Object($Value) {
    if ($Value -isnot [Collections.IDictionary]) { throw 'Invalid summary object.' }
}
function Read-Count($Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { throw 'Invalid aggregate count.' }
    [decimal]$number = 0
    if (-not [decimal]::TryParse(([string]$Value), [Globalization.NumberStyles]::Number,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
        $number -lt 0 -or $number -ne [decimal]::Truncate($number) -or $number -gt [long]::MaxValue) {
        throw 'Invalid aggregate count.'
    }
    $number
}
function Require-False($Value) {
    if ($Value -isnot [bool] -or $Value) { throw 'Source-only observation requires distributionAllowed=false and rawDataUploaded=false.' }
}
Require-Object $summary
Require-False $summary['distributionAllowed']
Require-False $summary['rawDataUploaded']
$usage = $summary['sourceUsage']; $join = $summary['joinQuality']
Require-Object $usage; Require-Object $join
if ($usage['ObservationScope'] -cne 'source-only') { throw 'Source-only scope is required.' }
Require-False $usage['DistributionAllowed']
$sourceRows = Read-Count $usage['SourceRows']
$known = Read-Count $usage['KnownPromptRows']
$unknown = Read-Count $usage['UnknownPromptRows']
if ($sourceRows -eq 0 -or $known + $unknown -ne $sourceRows) { throw 'Source row reconciliation failed.' }
$total = $usage['KnownPromptTotal']
if ($known -eq 0) {
    if ($null -ne $total) { throw 'No known rows requires a null prompt total.' }
}
else {
    if ($null -eq $total -or $total -is [string] -or $total -is [bool]) { throw 'Known rows require a numeric total.' }
    [decimal]$parsedTotal = 0
    if (-not [decimal]::TryParse(([string]$total), [Globalization.NumberStyles]::Number,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedTotal) -or
        $parsedTotal -lt 0 -or $parsedTotal -ne [decimal]::Truncate($parsedTotal) -or
        $parsedTotal -gt ([decimal][long]::MaxValue * $known)) { throw 'Invalid aggregate prompt total.' }
    $total = $parsedTotal
}
$matched = Read-Count $join['matchedUpnRows']
$unmatched = Read-Count $join['unmatchedUpnRows']
$missingDepartment = Read-Count $join['matchedWithoutDepartmentRows']
$anonymous = Read-Count $join['hex32IdentifierRows']
if ((Read-Count $join['sourceRows']) -ne $sourceRows -or $matched + $unmatched -ne $sourceRows -or
    $missingDepartment -gt $matched -or $anonymous -gt $sourceRows) { throw 'Join row reconciliation failed.' }
$probes = @($summary['periodProbes'] | Where-Object { $_ -is [Collections.IDictionary] -and $_['period'] -ceq 'D7' })
if ($probes.Count -ne 1 -or (Read-Count $probes[0]['status']) -ne 200 -or
    (Read-Count $probes[0]['rows']) -ne $sourceRows) { throw 'Successful primary D7 response is required.' }
$snapshot = & $module {
    param($source)
    Get-CopilotSnapshot ([ordered]@{ 'Report Refresh Date' = $source['ReportRefreshDate']; 'Report Period' = $source['ReportPeriod'] })
} $usage
if ($snapshot.ReportPeriod -cne '7') { throw 'Primary D7 requires report period 7.' }
$hash = $summary['sourceReportSha256']
if ($hash -isnot [string] -or $hash -cnotmatch '^[a-f0-9]{64}$') { throw 'A lowercase SHA256 source hash is required.' }
$collectedText = $summary['collectedAt']
if ($collectedText -is [datetime]) { $collectedText = $collectedText.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
$collected = [datetimeoffset]::MinValue
if ($collectedText -isnot [string] -or $collectedText -notmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,7})?(?:Z|[+-]\d\d:\d\d)$' -or
    -not [datetimeoffset]::TryParse($collectedText, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$collected)) { throw 'Valid collectedAt timestamp is required.' }
if ([datetime]::ParseExact($snapshot.ReportRefreshDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) -gt $collected.UtcDateTime.Date) {
    throw 'Report reference date cannot follow collection date.'
}
$rows = @(
    @('取得日時（UTC）', 'Collected at (UTC)', $collected.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss 'UTC'", [Globalization.CultureInfo]::InvariantCulture)),
    @('レポート基準日', 'Report reference date', $snapshot.ReportRefreshDate),
    @('対象期間（日数）', 'Report period (days)', $snapshot.ReportPeriod),
    @('取得元レポート行数', 'Source report rows', $sourceRows),
    @('プロンプト数が既知の行数', 'Rows with known prompt counts', $known),
    @('プロンプト数が不明の行数', 'Rows with unknown prompt counts', $unknown),
    @('既知の送信プロンプト数合計', 'Known prompt total', $total),
    @('UPN照合済み行数', 'Matched UPN rows', $matched),
    @('UPN未照合の行数', 'Unmatched UPN rows', $unmatched),
    @('照合済み・部門未設定の行数', 'Matched rows without department', $missingDepartment),
    @('32桁16進識別子の行数', 'Rows with 32-character hexadecimal identifiers', $anonymous),
    @('取得元CSVのSHA256', 'Source CSV SHA256', $hash)
)
$body = [Text.StringBuilder]::new()
foreach ($row in $rows) {
    $label = & $module { param($ja, $en) New-UiText $ja $en } $row[0] $row[1]
    $value = if ($null -eq $row[2]) { & $module { New-UiText '不明（既知値なし）' 'Unknown (no known values)' } }
        elseif ($row[2] -is [IFormattable]) { [Net.WebUtility]::HtmlEncode($row[2].ToString('0', [Globalization.CultureInfo]::InvariantCulture)) }
        else { [Net.WebUtility]::HtmlEncode([string]$row[2]) }
    [void]$body.Append('<tr><th scope="row">' + $label + '</th><td>' + $value + '</td></tr>')
}
$cards = [Text.StringBuilder]::new()
foreach ($card in @(
    @('レポート行数', 'Report rows', $sourceRows),
    @('判明プロンプト合計', 'Known prompt total', $total),
    @('UPN照合（照合済み／全体）', 'UPN matches (matched / source)', "$matched / $sourceRows")
)) {
    $label = & $module { param($ja, $en) New-UiText $ja $en } $card[0] $card[1]
    $value = if ($null -eq $card[2]) { & $module { New-UiText '不明（既知値なし）' 'Unknown (no known values)' } }
        elseif ($card[2] -is [IFormattable]) { [Net.WebUtility]::HtmlEncode($card[2].ToString('0', [Globalization.CultureInfo]::InvariantCulture)) }
        else { [Net.WebUtility]::HtmlEncode([string]$card[2]) }
    [void]$cards.Append('<div class="metric"><dt>' + $label + '</dt><dd>' + $value + '</dd></div>')
}
$pocRoot = Split-Path $PSScriptRoot -Parent
$sharedTemplate = Get-Content -LiteralPath (Join-Path $pocRoot 'templates\dashboard.html') -Raw -Encoding UTF8
$template = Get-Content -LiteralPath (Join-Path $pocRoot 'templates\source-observation.html') -Raw -Encoding UTF8
$scripts = [regex]::Matches($sharedTemplate, '<script>[\s\S]*?</script>')
$style = [regex]::Match($sharedTemplate, '<style>[\s\S]*?</style>')
if ($scripts.Count -ne 2 -or -not $style.Success) { throw 'Shared theme or language switch template contract changed.' }
$values = @{ STYLE = $style.Value; THEME = $scripts[0].Value; LANGUAGE = $scripts[1].Value; ROWS = $body.ToString(); METRICS = $cards.ToString(); RUNURL = [Net.WebUtility]::HtmlEncode($RunUrl) }
$html = [regex]::Replace($template, '\{\{(STYLE|THEME|LANGUAGE|ROWS|METRICS|RUNURL)\}\}', [Text.RegularExpressions.MatchEvaluator]{
    param($match)
    $values[$match.Groups[1].Value]
})
if ($PSCmdlet.ShouldProcess($output, 'Write private source-only observation HTML')) {
    [void][IO.Directory]::CreateDirectory($output)
    [IO.File]::WriteAllText((Join-Path $output 'index.html'), $html.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    $observation = [ordered]@{
        ObservationScope = 'source-only'
        DistributionAllowed = $false
        CollectedAt = $collected.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        ReportRefreshDate = $snapshot.ReportRefreshDate
        ReportPeriod = $snapshot.ReportPeriod
        SourceRows = $sourceRows
        KnownPromptRows = $known
        UnknownPromptRows = $unknown
        KnownPromptTotal = $total
        MatchedUpnRows = $matched
        UnmatchedUpnRows = $unmatched
        MatchedWithoutDepartmentRows = $missingDepartment
        Hex32IdentifierRows = $anonymous
        SourceReportSha256 = $hash
        RunUrl = $RunUrl
    }
    $csvRows = @([ordered]@{
        '観測範囲' = '取得元全体のみ・部門配信停止中'
        '取得日時（UTC）' = $observation.CollectedAt
        'レポート基準日' = $snapshot.ReportRefreshDate
        '対象期間（日数）' = $snapshot.ReportPeriod
        '取得元レポート行数' = $sourceRows
        'プロンプト数が既知の行数' = $known
        'プロンプト数が不明の行数' = $unknown
        '既知の送信プロンプト数合計' = $total
        'UPN照合済み行数' = $matched
        'UPN未照合の行数' = $unmatched
        '照合済み・部門未設定の行数' = $missingDepartment
        '32桁16進識別子の行数' = $anonymous
        '取得元CSVのSHA256' = $hash
    })
    $csv = & $module { param($items, $columns) ConvertTo-ReportCsv $items $columns } $csvRows @($csvRows[0].Keys)
    [IO.File]::WriteAllText((Join-Path $output 'source-observation.csv'), $csv, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $output 'source-observation.json'), ($observation | ConvertTo-Json -Depth 3) + "`n", [Text.UTF8Encoding]::new($false))
    [pscustomobject][ordered]@{
        Status = 'source-only'; DistributionAllowed = $false
        OutputDirectory = $output; HtmlPath = Join-Path $output 'index.html'
        CsvPath = Join-Path $output 'source-observation.csv'
        JsonPath = Join-Path $output 'source-observation.json'
        Sha256 = (Get-FileHash -LiteralPath (Join-Path $output 'index.html') -Algorithm SHA256).Hash.ToLowerInvariant()
        SourceRows = $sourceRows
    }
}
