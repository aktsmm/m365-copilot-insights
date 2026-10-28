#requires -Version 7.5
<#
.SYNOPSIS
検証済み暦月payloadから日本語既定の単体HTMLを生成します（集計・通信なし）。
.DESCRIPTION
Node.jsで共有rendererと同じschemaを検証します。tenantの保存先はworkspaceの
.localまたはRUNNER_TEMP配下のみ。既存ファイルとreparse pointは拒否します。
.EXAMPLE
.\Export-CopilotMonthlyDashboard.ps1 -PayloadPath .\monthly.json -OutputPath .\monthly.html -DataClass synthetic
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PayloadPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][ValidateSet('tenant', 'synthetic')][string]$DataClass,
    [switch]$ShowObservedCounts
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pocRoot = Split-Path $PSScriptRoot -Parent
$workspaceRoot = $pocRoot
$assets = Join-Path $pocRoot 'monthly-ui'
$node = (Get-Command node -ErrorAction Stop).Source
if (-not (Test-Path -LiteralPath $PayloadPath -PathType Leaf)) { throw 'Payload file not found.' }
$output = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $output) { throw 'OutputPath must not exist; choose a new run-specific filename.' }
function Assert-NoReparsePoint([string]$Path) {
    $current = $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not permitted in output paths.' }
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
}
Assert-NoReparsePoint $output
if ($DataClass -eq 'tenant') {
    $allowedRoots = @((Join-Path $workspaceRoot '.local'))
    if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $allowedRoots += $env:RUNNER_TEMP }
    $allowed = $false
    foreach ($root in $allowedRoots) {
        $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if ($output.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true }
    }
    if (-not $allowed) { throw 'Tenant output requires workspace .local or RUNNER_TEMP.' }
}
$raw = Get-Content -LiteralPath $PayloadPath -Raw -Encoding utf8
$payload = $raw | ConvertFrom-Json -AsHashtable -DateKind String
if ($payload.dataClass -cne $DataClass) { throw 'DataClass does not match the payload.' }
$raw | & $node (Join-Path $assets 'validate-payload.cjs') - | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Monthly payload validation failed.' }
$json = ($payload | ConvertTo-Json -Depth 100 -Compress).Replace('&', '\u0026').Replace('<', '\u003c').Replace('>', '\u003e').Replace([string][char]0x2028, '\u2028').Replace([string][char]0x2029, '\u2029')
$css = Get-Content -LiteralPath (Join-Path $assets 'dashboard.css') -Raw -Encoding utf8
$js = Get-Content -LiteralPath (Join-Path $assets 'dashboard.js') -Raw -Encoding utf8
$observed = if ($ShowObservedCounts) { 'true' } else { 'false' }
$html = @"
<!doctype html>
<html lang="ja"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Copilot 月次利用状況</title>
<script>
(() => {
  const param = new URLSearchParams(window.location.search).get("scoutTheme");
  const theme = param || (window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
  document.documentElement.setAttribute("data-theme", theme);
})();
</script>
<style>$css</style></head>
<body style="margin:0;background:var(--cp-bg);color:var(--cp-text)">
<main id="dashboard"><noscript>このダッシュボードの操作にはJavaScriptが必要です。 / JavaScript is required.</noscript></main>
<script id="monthly-payload" type="application/json">$json</script>
<script>$js</script>
<script>
try {
  CopilotMonthly.mount(document.getElementById("dashboard"), JSON.parse(document.getElementById("monthly-payload").textContent), {showObservedCounts:$observed});
} catch (error) {
  const root = document.getElementById("dashboard");
  root.setAttribute("role", "alert");
  root.textContent = "月次データを表示できません / Cannot display monthly data: " + error.message;
}
</script></body></html>
"@
$directory = Split-Path $output -Parent
if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory }
Assert-NoReparsePoint $output
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($html)
$stream = [IO.File]::Open($output, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
[pscustomobject]@{ OutputPath = $output; DataClass = $DataClass; Months = $payload.months.Count; Sha256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash }
