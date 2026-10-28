#requires -Version 7.5
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pocRoot = Split-Path $PSScriptRoot -Parent
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
if (Test-Path -LiteralPath $evidence) { throw 'EvidenceDirectory must not exist.' }
[void][IO.Directory]::CreateDirectory($evidence)
$results = @(foreach ($name in @('first', 'second')) {
    & (Join-Path $pocRoot 'scripts\Build-CopilotSyntheticPages.ps1') -OutputDirectory (Join-Path $evidence $name)
})
$first = Get-Content -LiteralPath (Join-Path $evidence 'first\manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
$second = Get-Content -LiteralPath (Join-Path $evidence 'second\manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if (($first | ConvertTo-Json -Depth 30 -Compress) -cne ($second | ConvertTo-Json -Depth 30 -Compress)) {
    throw 'Independent synthetic builds are not byte-reproducible.'
}
foreach ($build in @('first', 'second')) {
    $directory = Join-Path $evidence $build
    foreach ($entry in $first.files) {
        $actual = (Get-FileHash -LiteralPath (Join-Path $directory $entry.path) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $entry.sha256) { throw "Generated file differs from manifest: $($entry.path)" }
    }
    $html = Get-Content -LiteralPath (Join-Path $directory 'synthetic-monthly.html') -Raw -Encoding utf8
    if ($html -notmatch '完全合成データ・実績ではありません' -or
        $html -notmatch 'Fully synthetic, not actual usage' -or
        $html -notmatch 'dataClass.:.synthetic') { throw 'Synthetic disclosure missing.' }
}
$overwriteRejected = $false
try {
    & (Join-Path $pocRoot 'scripts\Build-CopilotSyntheticPages.ps1') -OutputDirectory (Join-Path $evidence 'first') | Out-Null
} catch {
    if ($_.Exception.Message -notlike 'OutputDirectory must not exist*') { throw }
    $overwriteRejected = $true
}
if (-not $overwriteRejected) { throw 'Existing output was not protected.' }
$summary = [ordered]@{
    status = 'passed'; generatedFilesPerBuild = $first.files.Count
    checks = @('independent-build-byte-identity', 'manifest-file-sha256', 'explicit-synthetic-disclosure', 'existing-output-rejected')
    fixtureSha256 = $first.monthlyFixture.canonicalSourceSha256
    payloadSha256 = $first.monthlyFixture.payloadSha256
    monthlyHtmlSha256 = $first.monthlyFixture.htmlSha256
    result = $results
}
$summary | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $evidence 'validation.json') -Encoding utf8
$summary | ConvertTo-Json -Depth 15
