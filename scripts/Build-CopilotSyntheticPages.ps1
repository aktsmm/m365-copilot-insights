#requires -Version 7.5
<#
.SYNOPSIS
公開用の固定合成fixtureだけで従来集計と月次UIの静的サイトを生成します。
.DESCRIPTION
入力payloadを受け取らず、実テナントやexportには接続しません。
既存出力は上書きしません。実測版はこの生成器の対象外です。
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pocRoot = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $pocRoot 'tests\fixtures\monthly-pages.cjs'
$node = (Get-Command node -ErrorAction Stop).Source
$fixtureText = (Get-Content -LiteralPath $fixture -Raw -Encoding utf8).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
$fixtureHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fixtureText))).ToLowerInvariant()
$expectedFixtureHash = '0921c715ffa838ecc80c4fe8dfa5a5cd5279aaf25878b3339aef4b00c4ca29b2'
if ($fixtureHash -cne $expectedFixtureHash) { throw 'Public monthly fixture differs from its reviewed allowlist.' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'OutputDirectory must not exist; choose a fresh build directory.' }
$result = & (Join-Path $PSScriptRoot 'Build-CopilotDashboard.ps1') `
    -UsersPath (Join-Path $pocRoot 'tests\fixtures\users.json') `
    -UsagePath (Join-Path $pocRoot 'tests\fixtures\usage.csv') `
    -OutputDirectory $output -DataClass synthetic
if ($result.Status -ne 'success' -or -not $result.DistributionAllowed) { throw 'Synthetic aggregate build is not distributable.' }
$json = & $node $fixture
if ($LASTEXITCODE -ne 0) { throw 'Synthetic monthly fixture generation failed.' }
$payload = $json | ConvertFrom-Json -AsHashtable -DateKind String
if ($payload.dataClass -cne 'synthetic' -or
    @($payload.months.rows | Where-Object { $_.upn -notmatch '^[a-z0-9]+@example\.invalid$' -or $_.userId -notlike 'synthetic-public-*' }).Count) {
    throw 'Public payload must contain only reserved synthetic identities.'
}
$payloadPath = Join-Path $output 'synthetic-monthly.json'
[IO.File]::WriteAllText($payloadPath, $json, [Text.UTF8Encoding]::new($false))
$monthly = & (Join-Path $PSScriptRoot 'Export-CopilotMonthlyDashboard.ps1') `
    -PayloadPath $payloadPath -OutputPath (Join-Path $output 'synthetic-monthly.html') -DataClass synthetic
$indexPath = Join-Path $output 'index.html'
$index = Get-Content -LiteralPath $indexPath -Raw -Encoding utf8
$navigation = '<nav aria-label="合成デモの表示切替" style="padding:1rem;background:var(--cp-surface);color:var(--cp-text);font-family:Segoe UI,Aptos,Calibri,sans-serif"><strong>完全合成データ・実績ではありません / Fully synthetic, not actual usage</strong><p><a style="color:var(--cp-link)" href="synthetic-monthly.html">月次・しきい値デモ / Monthly threshold demo</a> | <a style="color:var(--cp-link)" href="index.html">従来の期間集計 / Reporting-period summary</a></p></nav>'
if ($index -notmatch '<body>') { throw 'Synthetic aggregate HTML body marker missing.' }
[IO.File]::WriteAllText($indexPath, $index.Replace('<body>', "<body>$navigation"), [Text.UTF8Encoding]::new($false))
$monthlyPath = Join-Path $output 'synthetic-monthly.html'
$monthlyHtml = Get-Content -LiteralPath $monthlyPath -Raw -Encoding utf8
$monthlyHtml = $monthlyHtml.Replace('<main id="dashboard">', "$navigation<main id=`"dashboard`">")
[IO.File]::WriteAllText($monthlyPath, $monthlyHtml, [Text.UTF8Encoding]::new($false))
$manifestPath = Join-Path $output 'manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
$manifest.monthlyFixture = [ordered]@{
    id = 'independent-synthetic-pages-fixture-v1'
    canonicalSourceSha256 = $fixtureHash
    payloadSha256 = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    htmlSha256 = (Get-FileHash -LiteralPath $monthlyPath -Algorithm SHA256).Hash.ToLowerInvariant()
    disclaimer = 'Fully synthetic; not actual usage. No tenant source is read.'
}
$manifest.files = @(Get-ChildItem -LiteralPath $output -File -Recurse | Where-Object { $_.FullName -ne $manifestPath } |
    Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path = [IO.Path]::GetRelativePath($output, $_.FullName).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
[IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    Status = 'success'; DataClass = 'synthetic'; DistributionAllowed = $true
    FixtureSha256 = $fixtureHash; PayloadSha256 = $manifest.monthlyFixture.payloadSha256
    IndexSha256 = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant()
    MonthlySha256 = $manifest.monthlyFixture.htmlSha256; Months = $monthly.Months
}
