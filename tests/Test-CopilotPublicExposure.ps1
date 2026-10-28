#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot
$checks = 0
function Assert([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
$flows = Join-Path $root '.github\workflows'
foreach ($name in @('live-validation.yml','calendar-validation.yml')) {
    $text = Get-Content -LiteralPath (Join-Path $flows $name) -Raw
    Assert ($text -match 'workflow_dispatch:' -and $text -notmatch 'schedule:|push:|pull_request:') 'Backend must be manual-only'
    Assert ($text -notmatch 'upload-artifact|upload-pages-artifact|cache@|GITHUB_STEP_SUMMARY|Get-CopilotUsage|Get-CopilotCalendarProbe') 'Backend has a direct exposure path'
    Assert ($text -match 'Invoke-CopilotPrivateRun.ps1 -Mode (live|calendar)' -and $text -match 'id-token: write') 'Backend entry or permission mismatch'
    Assert ($text -match "github.repository == 'aktsmm/m365-copilot-insights'" -and $text -match "github.ref == 'refs/heads/main'") 'Backend ownership guard missing'
    Assert ($text -match 'group: copilot-private-publication') 'SPO writers must serialize across workflows'
}
$pages = Get-Content -LiteralPath (Join-Path $flows 'synthetic-pages.yml') -Raw
Assert ($pages -notmatch 'schedule:|TENANT_ID|COLLECTOR_CLIENT_ID|PUBLISHER_CLIENT_ID|SPO_|Get-CopilotUsage|Get-CopilotCalendarProbe') 'Pages must not use private source'
Assert ($pages -match 'Build-CopilotPublicPages.ps1' -and $pages -match 'workflow_dispatch:') 'Static Pages entry missing'
$probe = Get-Content -LiteralPath (Join-Path $flows 'oidc-probe.yml') -Raw
Assert ($probe -notmatch 'login.microsoftonline|graph.microsoft.com|Write.*token|ConvertTo-Json.*claims') 'Probe must not exchange Azure tokens or print the whole JWT'
Assert ($probe -match "'iss', 'aud', 'sub', 'repository', 'repository_id', 'repository_owner_id', 'ref'") 'OIDC claims allowlist drift'
$graph = Get-Content -LiteralPath (Join-Path $root 'scripts/Copilot.Graph.psm1') -Raw
Assert ($graph -notmatch '\$problem\.error|\$code=\$|throw.*location.Host') 'Graph failure must not reflect service data'
Assert (-not (Test-Path -LiteralPath (Join-Path $root 'scripts/Set-CopilotSiteGrant.ps1'))) 'Bootstrap must not ship'
foreach ($path in @('scripts/Publish-CopilotMonthly.ps1','scripts/Publish-CopilotSiteObservation.ps1')) {
    $text = Get-Content -LiteralPath (Join-Path $root $path) -Raw
    Assert ($text -match 'repo-\$env:GITHUB_REPOSITORY_ID-\$env:GITHUB_RUN_ID-\$env:GITHUB_RUN_ATTEMPT') 'New writes require repository-ID namespace'
}
$commentary = Get-Content -LiteralPath (Join-Path $flows 'synthetic-commentary.lock.yml') -Raw
Assert ($commentary -notmatch 'id-token:|TENANT_ID|COLLECTOR_CLIENT_ID|PUBLISHER_CLIENT_ID|SPO_') 'Agentic workflow has a private data capability'
Assert ($commentary -notmatch '(?m)^  schedule:') 'Agentic must be manual-only'

$work = Join-Path $PSScriptRoot ('public-exposure-'+[guid]::NewGuid().ToString('N'))
$saved = @{}
$keys = @('RUNNER_TEMP','GITHUB_REPOSITORY','GITHUB_REPOSITORY_ID','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_STEP_SUMMARY',
    'GITHUB_OUTPUT','GITHUB_ENV','GITHUB_PATH','GITHUB_STATE','EXPOSURE_FIXTURE_PHASE','TENANT_ID','COLLECTOR_CLIENT_ID',
    'PUBLISHER_CLIENT_ID','SPO_SITE_ID','SPO_LIBRARY_ID','SPO_SITE_PATH','SPO_OWNERSHIP_MARKER',
    'ACTIONS_ID_TOKEN_REQUEST_URL','ACTIONS_ID_TOKEN_REQUEST_TOKEN')
foreach ($key in $keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
try {
    [void][IO.Directory]::CreateDirectory($work)
    foreach ($script in @('Invoke-CopilotPrivateRun.ps1','Invoke-CopilotPrivateWorker.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root "scripts/$script") -Destination (Join-Path $work $script)
    }
    $stub = @'
[CmdletBinding()]
param($TenantId,$CollectorClientId,$PublisherClientId,$SiteId,$LibraryId,$OutputDirectory,$ArtifactDirectory,
    $SnapshotsPath,$Months,$PayloadPath,$OutputPath,$SummaryPath,$SourceDirectory,$RunUrl,$UsersPath,$UsagePath,$DataClass,
    [switch]$UseActions,[switch]$ProbePeriods,[switch]$ShowObservedCounts,[switch]$DepartmentReports,
    [switch]$PublishCurrentMetadata,[switch]$Apply)
$name = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$private = 'private-person@example.invalid response-body token-sentinel tenant-guid-sentinel'
[Console]::Out.WriteLine($private)
[Console]::Error.WriteLine($private)
Write-Warning $private
Write-Host $private
Write-Error $private -ErrorAction Continue
$private
foreach ($key in @('GITHUB_STEP_SUMMARY','GITHUB_OUTPUT','GITHUB_ENV','GITHUB_PATH','GITHUB_STATE')) {
    [IO.File]::AppendAllText([Environment]::GetEnvironmentVariable($key),$private)
}
if (($env:EXPOSURE_FIXTURE_PHASE -eq 'source' -and $name -like 'Get-*') -or
    ($env:EXPOSURE_FIXTURE_PHASE -eq 'publisher' -and $name -like 'Publish-*')) { throw $private }
if ($name -eq 'Get-CopilotCalendarProbe') {
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'probe-summary.json'),'{"reportRefreshDate":"2026-10-27"}')
}
'@
    foreach ($name in @('Get-CopilotUsage','Get-CopilotCalendarProbe','Restore-CopilotHistory',
        'Build-CopilotMonthly','Export-CopilotMonthlyDashboard','Publish-CopilotMonthly',
        'Export-CopilotSourceObservation','Publish-CopilotSiteObservation','Build-CopilotDashboard')) {
        [IO.File]::WriteAllText((Join-Path $work "$name.ps1"),$stub)
    }
    $env:RUNNER_TEMP = $work
    $env:GITHUB_REPOSITORY = 'aktsmm/m365-copilot-insights'
    $env:GITHUB_REPOSITORY_ID = '12345'
    $env:GITHUB_RUN_ID = '67890'
    $env:GITHUB_RUN_ATTEMPT = '1'
    foreach ($name in @('TENANT_ID','COLLECTOR_CLIENT_ID','PUBLISHER_CLIENT_ID','SPO_SITE_ID','SPO_LIBRARY_ID')) {
        [Environment]::SetEnvironmentVariable($name,'fixture-only')
    }
    foreach ($name in @('GITHUB_STEP_SUMMARY','GITHUB_OUTPUT','GITHUB_ENV','GITHUB_PATH','GITHUB_STATE')) {
        $path = Join-Path $work "$name-public.txt"
        [IO.File]::WriteAllText($path,'preserved')
        [Environment]::SetEnvironmentVariable($name,$path)
    }
    Import-Module (Join-Path $root 'scripts/Copilot.MonthlyPublish.psm1') -Force
    $env:SPO_SITE_PATH = ''
    $env:SPO_OWNERSHIP_MARKER = ''
    $caught = $null
    try {
        Connect-CopilotMonthlySite -TenantId ([guid]::Empty) -PublisherClientId ([guid]::Empty) `
            -SiteId "example.sharepoint.com,$([guid]::Empty),$([guid]::Empty)" -LibraryId ([guid]::Empty)
    } catch { $caught = $_.Exception.Message }
    Assert ($caught -ceq 'Explicit site path and ownership marker required') 'Generalization bypassed the site ownership guard'
    $module = Import-Module (Join-Path $root 'scripts/Copilot.Graph.psm1') -Force -PassThru
    & $module { function script:Invoke-RestMethod { throw 'private-auth-response-body@example.invalid' } }
    $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://example.invalid/?fixture=1'
    $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'fixture-only'
    $caught = $null
    try {
        Get-CopilotOidcToken -TenantId ([guid]::Empty) -ClientId ([guid]::Empty) -ExpectedRoles @('Sites.Selected')
    } catch { $caught = $_.Exception.Message }
    Assert ($caught -ceq 'OIDC authentication failed; private response details suppressed') 'Auth failure reflected a private response body'
    Remove-Module $module
    foreach ($mode in @('live','calendar')) {
        foreach ($phase in @('success','source','publisher')) {
            $env:EXPOSURE_FIXTURE_PHASE = $phase
            $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $work 'Invoke-CopilotPrivateRun.ps1'),'-Mode',$mode)) {
                $start.ArgumentList.Add($arg)
            }
            $child = [Diagnostics.Process]::Start($start)
            $outTask = $child.StandardOutput.ReadToEndAsync()
            $errTask = $child.StandardError.ReadToEndAsync()
            $child.WaitForExit()
            $text = $outTask.GetAwaiter().GetResult()
            $errorText = $errTask.GetAwaiter().GetResult()
            $exitCode = $child.ExitCode
            $child.Dispose()
            $expected = if ($phase -eq 'success') { 'succeeded' } else { 'failed' }
            Assert (($exitCode -eq 0) -eq ($phase -eq 'success')) 'Private failure was converted into success'
            Assert ($errorText.Length -eq 0 -and $text -notmatch 'private-person|response-body|token-sentinel|tenant-guid|sharepoint|RUNNER_TEMP') 'Private stdout/stderr escaped'
            $result = $text | ConvertFrom-Json -AsHashtable
            Assert ($result.status -ceq $expected -and $result.operation -ceq $mode -and -not $result.privateOutputPublished -and $result.Count -eq 4) 'Public status is not bounded'
            Assert (@(Get-ChildItem -LiteralPath $work -Directory -Filter 'copilot-private-*').Count -eq 0) 'Private runner files survived cleanup'
            foreach ($name in @('GITHUB_STEP_SUMMARY','GITHUB_OUTPUT','GITHUB_ENV','GITHUB_PATH','GITHUB_STATE')) {
                Assert ((Get-Content -LiteralPath ([Environment]::GetEnvironmentVariable($name)) -Raw) -ceq 'preserved') 'Private process modified public workflow output'
            }
        }
    }
    Write-Output "Public exposure: $checks deterministic checks passed (success/source-failure/publisher-failure fixtures; no live data)."
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
