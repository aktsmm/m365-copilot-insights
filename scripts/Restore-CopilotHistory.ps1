#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$PublisherClientId,
    [Parameter(Mandatory)][string]$SiteId,
    [Parameter(Mandatory)][guid]$LibraryId,
    [Parameter(Mandatory)][string]$ArtifactDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $env:RUNNER_TEMP) { throw 'Runner storage required.' }
$root=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar)
$target=[IO.Path]::GetFullPath($ArtifactDirectory)
if ($target -ine $root -and -not $target.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Runner storage required.' }
Import-Module (Join-Path $PSScriptRoot 'Copilot.MonthlyPublish.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Copilot.History.psm1') -Force
function Get-CalendarMonths([string]$RefreshDate) {
    # Include the previous month so a month rollover keeps the finished month current and never leaves the new month without snapshots.
    $d = [datetime]::ParseExact($RefreshDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    @($d.AddMonths(-1).ToString('yyyy-MM'), $d.ToString('yyyy-MM')) | Where-Object { $_ -ge '2026-10' }
}
$summary=Get-Content (Join-Path $target 'calendar-probe\probe-summary.json') -Raw -Encoding utf8|ConvertFrom-Json -AsHashtable -DateKind String
$connection=Connect-CopilotMonthlySite -TenantId $TenantId -PublisherClientId $PublisherClientId -SiteId $SiteId -LibraryId $LibraryId
$result=Restore-CopilotMonthlyHistory -Request $connection.Request -OutputDirectory (Join-Path $target 'calendar-history') `
    -Months @(Get-CalendarMonths $summary.reportRefreshDate) -ExpectedSource $summary.source -ExpectedMetricId 'all-apps-actions' `
    -ExpectedDateBasis 'UTC' -DataClass tenant -AsOfDate ([DateTime]::UtcNow.ToString('yyyy-MM-dd')) -GeneratedAt ([DateTime]::UtcNow.ToString('o'))
$combined=Join-Path $target 'calendar-combined-snapshots'
if(Test-Path -LiteralPath $combined){throw 'Combined snapshots already exist; do not overwrite.'}
[void][IO.Directory]::CreateDirectory($combined)
foreach($file in Get-ChildItem -LiteralPath $result.SnapshotDirectory -File -Filter '*.json'){
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $combined ("history-"+$file.Name))
}
$currentSnapshots=Join-Path $target 'calendar-probe\snapshots'
if(Test-Path -LiteralPath $currentSnapshots){
foreach($file in Get-ChildItem -LiteralPath $currentSnapshots -File -Filter '*.json'){
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $combined ("current-"+$file.Name))
}
}
Write-Output "Validated historical snapshots=$($result.SnapshotCount); uncommitted folders=$(@($result.UncommittedRunKeys).Count). No empty day is counted as zero."
