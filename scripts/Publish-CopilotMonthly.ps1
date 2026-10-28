#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$PublisherClientId,
    [Parameter(Mandatory)][string]$SiteId,
    [Parameter(Mandatory)][guid]$LibraryId,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$SwitchCurrent,
    [switch]$PublishCurrentMetadata,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($SwitchCurrent) { throw 'Content PUT current switching is retired; use PublishCurrentMetadata.' }
if ($SiteId -notmatch '^[a-z0-9-]+\.sharepoint\.com,[0-9a-f-]{36},[0-9a-f-]{36}$') { throw 'Invalid composite site ID.' }
if ($env:GITHUB_REPOSITORY -cne 'aktsmm/m365-copilot-insights' -or
    $env:GITHUB_REPOSITORY_ID -notmatch '^[1-9][0-9]*$' -or $env:GITHUB_RUN_ID -notmatch '^[0-9]+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^[0-9]+$') { throw 'Owned Actions run context required.' }
if (-not $env:RUNNER_TEMP) { throw 'Runner storage required.' }
$runnerRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar)
$prefix = $runnerRoot + [IO.Path]::DirectorySeparatorChar
if (-not [IO.Path]::GetFullPath($OutputPath).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
    ([IO.Path]::GetFullPath($ArtifactDirectory) -ine $runnerRoot -and
     -not [IO.Path]::GetFullPath($ArtifactDirectory).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
    throw 'Runner storage required.'
}
if (Test-Path -LiteralPath $OutputPath) { throw 'Existing publication evidence is preserved.' }
$proof = @{ observedAt=[DateTime]::UtcNow.ToString('o'); runKey="repo-$env:GITHUB_REPOSITORY_ID-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"; complete=$false; files=@(); folders=@() }
$html = $null
$htmlCreated = $false
try {
    $verification = Join-Path (Split-Path $OutputPath) 'monthly-revalidation.json'
    [void][IO.Directory]::CreateDirectory((Split-Path $OutputPath))
    $verificationArgs = @{ ArtifactDirectory=$ArtifactDirectory; EvidencePath=$verification }
    $historySnapshots = Join-Path $ArtifactDirectory 'calendar-history\snapshots'
    if (Test-Path -LiteralPath $historySnapshots) { $verificationArgs.HistorySnapshotsPath=$historySnapshots }
    & (Join-Path $PSScriptRoot '..\tests\Test-CopilotCalendarProbeResult.ps1') @verificationArgs | Out-Null
    $derived = Join-Path $ArtifactDirectory 'calendar-monthly'
    $raw = Join-Path $ArtifactDirectory 'calendar-probe'
    $artifacts = @{}
    $manifest = Get-Content (Join-Path $derived 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($file in $manifest.files) {
        if ($file.path -cnotmatch '^(monthly\.json|\d{4}-\d{2}-[a-z0-9-]+\.csv)$') { throw 'Derived manifest path rejected.' }
        $path = Join-Path $derived $file.path
        if ((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $file.sha256) { throw 'Derived manifest hash mismatch.' }
        $artifacts[$file.path] = [IO.File]::ReadAllBytes($path)
    }
    $artifacts['manifest.json'] = [IO.File]::ReadAllBytes((Join-Path $derived 'manifest.json'))
    $html = Join-Path (Split-Path $OutputPath) ("regenerated-$([guid]::NewGuid().ToString('N')).html")
    & (Join-Path $PSScriptRoot 'Export-CopilotMonthlyDashboard.ps1') -PayloadPath (Join-Path $derived 'monthly.json') -OutputPath $html -DataClass tenant -ShowObservedCounts | Out-Null
    $htmlCreated = $true
    $sourceHtml = Join-Path $derived 'monthly-dashboard.html'
    $expectedHtml = (Get-Content $html -Raw -Encoding utf8).Replace("`r`n","`n")
    $actualHtml = (Get-Content $sourceHtml -Raw -Encoding utf8).Replace("`r`n","`n")
    if ($expectedHtml -cne $actualHtml) { throw 'HTML differs from validated regeneration (newline normalization only).' }
    $artifacts['monthly-dashboard.html'] = [IO.File]::ReadAllBytes($sourceHtml)
    $rawArtifacts = @{}
    foreach ($file in Get-ChildItem -LiteralPath $raw -File) {
        if ($file.Name -cmatch '^(users\.json|usage-D28\.csv|probe-summary\.json|raw-\d{4}-\d{2}-\d{2}\.json)$') {
            $rawArtifacts[$file.Name] = [IO.File]::ReadAllBytes($file.FullName)
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $raw 'snapshots') -File -Filter '*.json') {
        $rawArtifacts["snapshot-$($file.Name)"] = [IO.File]::ReadAllBytes($file.FullName)
    }
    Import-Module (Join-Path $PSScriptRoot 'Copilot.MonthlyPublish.psm1') -Force
    if ($Apply) {
        $connection = Connect-CopilotMonthlySite -TenantId $TenantId -PublisherClientId $PublisherClientId -SiteId $SiteId -LibraryId $LibraryId
        $proof.driveId = $connection.DriveId
        $proof.applicationAuthenticationVerified = $true
        $request = $connection.Request
        if ($PublishCurrentMetadata) {
            Import-Module (Join-Path $PSScriptRoot 'Copilot.CurrentPointer.psm1') -Force
            $pointerBefore = Initialize-CopilotCurrentPointer -Request $request -Proof $proof
        }
    } else {
        $request = { throw 'Dry-run must not invoke any network request.' }
    }
    Publish-CopilotMonthlyFiles -Request $request -RunKey $proof.runKey -Artifacts $artifacts -RawArtifacts $rawArtifacts -Proof $proof -SwitchCurrent:$SwitchCurrent -Apply:$Apply
    if ($Apply -and $PublishCurrentMetadata) {
        $proof.complete = $false
        Import-Module (Join-Path $PSScriptRoot 'Copilot.History.psm1') -Force
        $payload = [Text.Encoding]::UTF8.GetString($artifacts['monthly.json']) | ConvertFrom-Json -AsHashtable -DateKind String
        $month = $payload.months[0]
        $restoreArgs = @{
            Request=$request; OutputDirectory=(Join-Path (Split-Path $OutputPath) 'restored-current')
            Months=@($payload.months.month); ExpectedSource=$month.source; ExpectedMetricId=$month.metricId
            ExpectedDateBasis=$month.dateBasis; DataClass='tenant'
            AsOfDate=([DateTimeOffset]::Parse($payload.generatedAt).UtcDateTime.ToString('yyyy-MM-dd'))
            GeneratedAt=$payload.generatedAt
        }
        # All published runs preserve historical dates that have rolled out of the newest source window.
        $restored = Restore-CopilotMonthlyHistory @restoreArgs
        $rebuiltText = Get-Content -LiteralPath $restored.MonthlyPath -Raw -Encoding utf8
        $expectedNode = [System.Text.Json.Nodes.JsonNode]::Parse([Text.Encoding]::UTF8.GetString($artifacts['monthly.json']))
        $actualNode = [System.Text.Json.Nodes.JsonNode]::Parse($rebuiltText)
        if (-not [System.Text.Json.Nodes.JsonNode]::DeepEquals($expectedNode,$actualNode)) { throw 'SPO history reconstruction differs from the published monthly payload; current untouched.' }
        $proof.historyReconstruction = @{
            verified=$true; snapshots=$restored.SnapshotCount; uncommittedRunKeys=@($restored.UncommittedRunKeys)
            manifest=(Split-Path $restored.ManifestPath -Leaf); comparison='all JSON values; original generatedAt'
        }
        $proof.complete = $true
        $payloadSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($artifacts['monthly.json'])).ToLowerInvariant()
        Set-CopilotCurrentPointer -Request $request -Before $pointerBefore -RunKey $proof.runKey -PayloadSha256 $payloadSha -Proof $proof
    }
    Write-Output "Monthly publisher: complete=$($proof.complete), verifiedFiles=$(@($proof.files | Where-Object readbackVerified).Count)"
} finally {
    if ($htmlCreated -and (Test-Path -LiteralPath $html)) { Remove-Item -LiteralPath $html -Force }
    [void][IO.Directory]::CreateDirectory((Split-Path $OutputPath))
    [IO.File]::WriteAllText($OutputPath, ($proof | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}
