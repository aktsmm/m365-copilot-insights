#Requires -Version 7.5
# Temporary diagnostic: runs the calendar stages and prints only the stage name and a redacted exception message.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Get-CalendarMonths([string]$RefreshDate) {
    $d = [datetime]::ParseExact($RefreshDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    @($d.AddMonths(-1).ToString('yyyy-MM'), $d.ToString('yyyy-MM')) | Where-Object { $_ -ge '2026-10' }
}
function Show-Redacted([string]$Stage, $ErrorRecord) {
    $text = "$($ErrorRecord.Exception.Message)"
    $text = [regex]::Replace($text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<guid>')
    $text = [regex]::Replace($text, '[\w.+-]+@[\w.-]+', '<mail>')
    if ($text.Length -gt 220) { $text = $text.Substring(0, 220) }
    $line = $ErrorRecord.InvocationInfo.ScriptLineNumber
    $file = Split-Path -Leaf "$($ErrorRecord.InvocationInfo.ScriptName)"
    Write-Output "DIAG stage=$Stage file=$file line=$line message=$text"
}
$common = @{ TenantId = $env:TENANT_ID; PublisherClientId = $env:PUBLISHER_CLIENT_ID; SiteId = $env:SPO_SITE_ID; LibraryId = $env:SPO_LIBRARY_ID }
$work = $env:RUNNER_TEMP
$stage = 'probe'
try {
    & (Join-Path $PSScriptRoot 'Get-CopilotCalendarProbe.ps1') -TenantId $env:TENANT_ID -CollectorClientId $env:COLLECTOR_CLIENT_ID -UseActions -OutputDirectory (Join-Path $work 'calendar-probe') | Out-Null
    $summary = Get-Content (Join-Path $work 'calendar-probe\probe-summary.json') -Raw | ConvertFrom-Json
    Write-Output "DIAG probe ok refresh=$($summary.reportRefreshDate) roster=$($summary.rosterPeriod) days=$(@($summary.days | ForEach-Object { '{0}:{1}' -f $_.date.Substring(5), $_.errorCode + $_.status }) -join ',')"
    $stage = 'restore'
    & (Join-Path $PSScriptRoot 'Restore-CopilotHistory.ps1') @common -ArtifactDirectory $work | Out-Null
    Write-Output 'DIAG restore ok'
    $stage = 'build'
    & (Join-Path $PSScriptRoot 'Build-CopilotMonthly.ps1') -SnapshotsPath (Join-Path $work 'calendar-combined-snapshots') -Months @(Get-CalendarMonths $summary.reportRefreshDate) -OutputDirectory (Join-Path $work 'calendar-monthly') | Out-Null
    Write-Output 'DIAG build ok'
    $stage = 'dashboard'
    & (Join-Path $PSScriptRoot 'Export-CopilotMonthlyDashboard.ps1') -PayloadPath (Join-Path $work 'calendar-monthly\monthly.json') -OutputPath (Join-Path $work 'calendar-monthly\monthly-dashboard.html') -DataClass tenant -ShowObservedCounts | Out-Null
    Write-Output 'DIAG dashboard ok'
    $stage = 'publish'
    & (Join-Path $PSScriptRoot 'Publish-CopilotMonthly.ps1') @common -ArtifactDirectory $work -OutputPath (Join-Path $work 'calendar-publication\result.json') -PublishCurrentMetadata -Apply | Out-Null
    Write-Output 'DIAG publish ok'
} catch {
    Show-Redacted $stage $_
    exit 1
}
