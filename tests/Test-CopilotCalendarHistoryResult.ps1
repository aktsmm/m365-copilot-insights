#requires -Version 7.5
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$verifier=Join-Path $PSScriptRoot 'Test-CopilotCalendarProbeResult.ps1'
$work=Join-Path $PSScriptRoot ('.history-result-test-'+[guid]::NewGuid().ToString('N'))
$script:Assertions=0
$script:Case=0
function Assert-True([bool]$Condition,[string]$Message) {
    $script:Assertions++
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}
function Assert-Throws([scriptblock]$Action,[string]$Pattern) {
    $caught=$null
    try { & $Action | Out-Null } catch { $caught=$_ }
    Assert-True ($null -ne $caught) "Expected $Pattern"
    Assert-True ($caught.Exception.Message -match $Pattern) "Error mismatch: $caught"
}
function Write-Json([string]$Path,[object]$Value) {
    [IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 20),[Text.UTF8Encoding]::new($false))
}
function New-Snapshot([string]$Date,[object]$Count=1,[string]$Time='2026-10-28T00:00:00Z') {
    @{
        schemaVersion=1;dataClass='tenant';source='graph-beta-usage-by-date';metricId='all-apps-actions'
        metricLabelJa='アクション数';metricLabelEn='Actions';dateBasis='UTC';selectedDate=$Date
        reportRefreshDate='2026-10-27';collectedAt=$Time;collectionComplete=$true
        users=@(0..49 | ForEach-Object { @{userId="id-$_";upn="user$_@example.invalid";displayName="User $_";department='A';count=$Count} })
    }
}
function New-Artifact([object[]]$History=@(),[long]$Observed=7,[int]$Known=7,[string[]]$ExtraDates=@()) {
    $script:Case++
    $artifact=Join-Path $work "case-$script:Case"
    $probe=Join-Path $artifact 'calendar-probe'
    $snapshots=Join-Path $probe 'snapshots'
    $historyPath=Join-Path $artifact 'history'
    $monthlyPath=Join-Path $artifact 'calendar-monthly'
    foreach ($path in @($snapshots,$historyPath,$monthlyPath)) { [void][IO.Directory]::CreateDirectory($path) }
    $days=@()
    foreach ($i in 0..7) {
        $date="2026-10-$($i+20)"
        $snapshot=New-Snapshot $date
        $raw=@()
        if ($i -eq 0) {
            $snapshot.collectionComplete=$false
            foreach ($user in $snapshot.users) { $user.count=$null }
        } else {
            $raw=@(0..49 | ForEach-Object {
                @{userPrincipalName="user$_@example.invalid";reportSelectedDate=$date;reportRefreshDate='2026-10-27';allAppsCopilotActionCount=1}
            })
        }
        Write-Json (Join-Path $probe "raw-$date.json") @{value=$raw}
        Write-Json (Join-Path $snapshots "$date.json") $snapshot
        $days+=@{date=$date;status=200;fields=@('allAppsCopilotActionCount');rows=$raw.Count}
    }
    Write-Json (Join-Path $probe 'users.json') @{value=@(0..49 | ForEach-Object { @{id="id-$_";userPrincipalName="user$_@example.invalid"} })}
    $roster=@(0..49 | ForEach-Object { [pscustomobject]@{'User Principal Name'="user$_@example.invalid"} })
    $roster | Export-Csv -LiteralPath (Join-Path $probe 'usage-D28.csv') -Encoding utf8 -NoTypeInformation
    Write-Json (Join-Path $probe 'probe-summary.json') @{
        runtimeApplicationVerified=$true;allAppsPromptMetricAvailable=$false;source='graph-beta-usage-by-date'
        reportRefreshDate='2026-10-27';days=$days
    }
    $expected=@(1..31 | ForEach-Object { '2026-10-'+$_.ToString('00') })
    $available=@(@(21..27 | ForEach-Object { "2026-10-$_" })+$ExtraDates | Sort-Object -Unique)
    Write-Json (Join-Path $monthlyPath 'monthly.json') @{
        schemaVersion=1;dataClass='tenant';generatedAt='2026-10-28T02:00:00Z'
        months=@(@{
            month='2026-10';metricId='all-apps-actions';source='graph-beta-usage-by-date'
            coverage=@{expectedDates=$expected;availableDates=$available;missingDates=@($expected | Where-Object { $_ -notin $available });status='in-progress'}
            rows=@(0..49 | ForEach-Object {
                @{userId="id-$_";upn="user$_@example.invalid";observedCount=$Observed;knownDays=$Known;unknownDays=(31-$Known);count=$null;status='unknown'}
            })
        })
    }
    $index=0
    foreach ($snapshot in $History) { Write-Json (Join-Path $historyPath "prior-$index.json") $snapshot; $index++ }
    @{ArtifactDirectory=$artifact;EvidencePath=(Join-Path $artifact 'evidence.json');HistorySnapshotsPath=$historyPath}
}
function Read-Monthly([hashtable]$Parameters) {
    Get-Content -LiteralPath (Join-Path $Parameters.ArtifactDirectory 'calendar-monthly\monthly.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
}
function Write-Monthly([hashtable]$Parameters,[object]$Value) {
    Write-Json (Join-Path $Parameters.ArtifactDirectory 'calendar-monthly\monthly.json') $Value
}
try {
    [void][IO.Directory]::CreateDirectory($work)
    foreach ($file in @($verifier,$PSCommandPath)) {
        $errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$null,[ref]$errors)
        Assert-True (@($errors).Count -eq 0) 'PowerShell syntax'
    }
    $p=New-Artifact; $p.Remove('HistorySnapshotsPath')
    & $verifier @p | Out-Null
    $e=Get-Content -LiteralPath $p.EvidencePath -Raw | ConvertFrom-Json
    Assert-True ($e.assertions -eq 1706 -and $e.historySnapshotCount -eq 0) 'No-history compatibility retains exactly 1706 source checks'
    Assert-True ($e.currentRawReconciled -and -not $e.historicalRawReconciled) 'Evidence boundary is explicit'
    $p=New-Artifact -History @((New-Snapshot '2026-10-01' 2)) -Observed 9 -Known 8 -ExtraDates @('2026-10-01')
    & $verifier @p | Out-Null
    Assert-True (Test-Path -LiteralPath $p.EvidencePath) 'Older source date extends history coverage'
    $p=New-Artifact -History @((New-Snapshot '2026-10-21' 4 '2026-10-28T01:00:00Z')) -Observed 10
    & $verifier @p | Out-Null
    Assert-True (Test-Path -LiteralPath $p.EvidencePath) 'Newer historical correction replaces current-day value'
    $p=New-Artifact -History @((New-Snapshot '2026-10-21' 99 '2026-10-27T23:00:00Z'))
    & $verifier @p | Out-Null
    Assert-True (Test-Path -LiteralPath $p.EvidencePath) 'Newer current snapshot replaces older historical value'
    $p=New-Artifact -History @((New-Snapshot '2026-10-01' 0)) -Known 8 -ExtraDates @('2026-10-01')
    & $verifier @p | Out-Null
    Assert-True (Test-Path -LiteralPath $p.EvidencePath) 'Explicit zero adds known day without adding actions'
    $p=New-Artifact -History @((New-Snapshot '2026-10-01' $null)) -ExtraDates @('2026-10-01')
    & $verifier @p | Out-Null
    Assert-True (Test-Path -LiteralPath $p.EvidencePath) 'Null history adds availability but not a known user day'
    $p=New-Artifact -History @((New-Snapshot '2026-10-21'))
    & $verifier @p | Out-Null
    Assert-True (Test-Path -LiteralPath $p.EvidencePath) 'Identical same-time duplicate is idempotent'
    $p=New-Artifact -History @((New-Snapshot '2026-10-21' 2))
    Assert-Throws { & $verifier @p } 'Conflicting duplicate'
    Assert-True (-not (Test-Path -LiteralPath $p.EvidencePath)) 'Conflict emits no success evidence'
    foreach ($field in @('source','metricId','dateBasis','dataClass')) {
        $bad=New-Snapshot '2026-10-01'; $bad[$field]='forged'
        $p=New-Artifact -History @($bad)
        Assert-Throws { & $verifier @p } 'provenance mismatch'
    }
    foreach ($mutation in @('outside','duplicate','missingCount','negative','fractional','date','absentUser')) {
        $bad=New-Snapshot '2026-10-01'
        switch ($mutation) {
            outside { $bad.users[0].upn='outside@example.invalid' }
            duplicate { $bad.users[0]=$bad.users[1] }
            missingCount { $bad.users[0].Remove('count') }
            negative { $bad.users[0].count=-1 }
            fractional { $bad.users[0].count=1.5 }
            date { $bad.selectedDate='2026-10-29' }
            absentUser { $bad.users=@($bad.users | Select-Object -Skip 1) }
        }
        $p=New-Artifact -History @($bad)
        Assert-Throws { & $verifier @p } 'roster|schema|count|date|missing'
    }
    $p=New-Artifact -History @((New-Snapshot '2026-10-01' $null)) -Known 8 -ExtraDates @('2026-10-01')
    Assert-Throws { & $verifier @p } 'Monthly values'
    $p=New-Artifact -History @((New-Snapshot '2026-10-01' 0)) -ExtraDates @('2026-10-01')
    Assert-Throws { & $verifier @p } 'Monthly values'
    $p=New-Artifact; $m=Read-Monthly $p; $m.months[0].rows[0].count=0; Write-Monthly $p $m
    Assert-Throws { & $verifier @p } 'Incomplete data'
    $p=New-Artifact; $m=Read-Monthly $p; $m.months[0].coverage.availableDates+=@('2026-10-01'); Write-Monthly $p $m
    Assert-Throws { & $verifier @p } 'Monthly coverage'
    $p=New-Artifact; $m=Read-Monthly $p; $m.months[0].rows[0].observedCount='7'; Write-Monthly $p $m
    Assert-Throws { & $verifier @p } 'Invalid source count'
    foreach ($mutation in @('source','date','rawValue')) {
        $p=New-Artifact
        $path=Join-Path $p.ArtifactDirectory 'calendar-probe\snapshots\2026-10-21.json'
        $value=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        switch ($mutation) {
            source { $value.source='forged' }
            date { $value.selectedDate='2026-10-22' }
            rawValue { $value.users[0].count=0 }
        }
        Write-Json $path $value
        Assert-Throws { & $verifier @p } 'Snapshot metric drift|Snapshot date drift|Daily source value was changed'
    }
    Write-Output "PASS: $script:Assertions assertions; no-history verifier 1706 checks preserved; history/current independent reconciliation fixtures only"
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
