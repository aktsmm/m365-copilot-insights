#Requires -Version 7.5
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('live','calendar')][string]$Mode)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Get-CalendarMonths([string]$RefreshDate) {
    # Include the previous month so a month rollover keeps the finished month current and never leaves the new month without snapshots.
    $d = [datetime]::ParseExact($RefreshDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    @($d.AddMonths(-1).ToString('yyyy-MM'), $d.ToString('yyyy-MM')) | Where-Object { $_ -ge '2026-10' }
}
$common = @{
    TenantId=$env:TENANT_ID; PublisherClientId=$env:PUBLISHER_CLIENT_ID
    SiteId=$env:SPO_SITE_ID; LibraryId=$env:SPO_LIBRARY_ID
}
$stage = 'start'
try {
if ($Mode -eq 'calendar') {
    $stage = 'probe'
    & (Join-Path $PSScriptRoot 'Get-CopilotCalendarProbe.ps1') -TenantId $env:TENANT_ID -CollectorClientId $env:COLLECTOR_CLIENT_ID -UseActions -OutputDirectory (Join-Path $env:RUNNER_TEMP 'calendar-probe')
    $stage = 'restore'
    & (Join-Path $PSScriptRoot 'Restore-CopilotHistory.ps1') @common -ArtifactDirectory $env:RUNNER_TEMP
    $summary = Get-Content (Join-Path $env:RUNNER_TEMP 'calendar-probe\probe-summary.json') -Raw | ConvertFrom-Json
    $stage = 'build'
    & (Join-Path $PSScriptRoot 'Build-CopilotMonthly.ps1') -SnapshotsPath (Join-Path $env:RUNNER_TEMP 'calendar-combined-snapshots') -Months @(Get-CalendarMonths $summary.reportRefreshDate) -OutputDirectory (Join-Path $env:RUNNER_TEMP 'calendar-monthly')
    $stage = 'dashboard'
    & (Join-Path $PSScriptRoot 'Export-CopilotMonthlyDashboard.ps1') -PayloadPath (Join-Path $env:RUNNER_TEMP 'calendar-monthly\monthly.json') -OutputPath (Join-Path $env:RUNNER_TEMP 'calendar-monthly\monthly-dashboard.html') -DataClass tenant -ShowObservedCounts
    $stage = 'publish'
    & (Join-Path $PSScriptRoot 'Publish-CopilotMonthly.ps1') @common -ArtifactDirectory $env:RUNNER_TEMP -OutputPath (Join-Path $env:RUNNER_TEMP 'calendar-publication\result.json') -PublishCurrentMetadata -Apply
} else {
    $source = Join-Path $env:RUNNER_TEMP 'copilot-live'
    $observation = Join-Path $env:RUNNER_TEMP 'copilot-observation'
    $build = Join-Path $env:RUNNER_TEMP 'copilot-build'
    $stage = 'collect'
    & (Join-Path $PSScriptRoot 'Get-CopilotUsage.ps1') -TenantId $env:TENANT_ID -CollectorClientId $env:COLLECTOR_CLIENT_ID -PublisherClientId $env:PUBLISHER_CLIENT_ID -OutputDirectory $source -ProbePeriods
    $summary = Join-Path $source 'collection-summary.json'
    $stage = 'observe'
    & (Join-Path $PSScriptRoot 'Export-CopilotSourceObservation.ps1') -SummaryPath $summary -OutputDirectory $observation -RunUrl "https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    $stage = 'publish-observation'
    & (Join-Path $PSScriptRoot 'Publish-CopilotSiteObservation.ps1') @common -SummaryPath $summary -SourceDirectory $observation -OutputPath (Join-Path $env:RUNNER_TEMP 'copilot-publish\result.json') -Apply
    $users = Join-Path $source 'users.json'
    $usage = Join-Path $source 'usage-D7.csv'
    $stage = 'build-dashboard'
    & (Join-Path $PSScriptRoot 'Build-CopilotDashboard.ps1') -UsersPath $users -UsagePath $usage -OutputDirectory $build -DataClass tenant
    $stage = 'publish-departments'
    & (Join-Path $PSScriptRoot 'Publish-CopilotSiteObservation.ps1') @common -DepartmentReports -SummaryPath $summary -SourceDirectory $build -UsersPath $users -UsagePath $usage -OutputPath (Join-Path $env:RUNNER_TEMP 'copilot-department-publish\result.json') -Apply
}
} catch {
    [Console]::Out.WriteLine("STAGE_FAILED:$stage")
    throw
}
