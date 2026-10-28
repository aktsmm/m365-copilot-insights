#requires -Version 7.5
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts/Copilot.History.psm1') -Force
Import-Module (Join-Path $root 'scripts/Copilot.Calendar.psm1')
$work=Join-Path $PSScriptRoot ('.history-test-'+[guid]::NewGuid().ToString('N'))
$oldRunner=$env:RUNNER_TEMP
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
function Get-Bytes([object]$Value) {
    ,([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 20 -Compress)))
}
function New-Snapshot([object]$Count=0,[string]$Collected='2026-10-28T00:00:00Z') {
    @{
        schemaVersion=1;dataClass='tenant';source='graph-beta-actions';metricId='all-apps-actions'
        metricLabelJa='アクション数';metricLabelEn='Actions';dateBasis='UTC/source-date'
        selectedDate='2026-10-20';reportRefreshDate='2026-10-27';collectedAt=$Collected;collectionComplete=$true
        users=@(@{userId='a';upn='a@example.invalid';displayName='A';department='A';count=$Count})
    }
}
function Set-JsonResponse([hashtable]$Map,[string]$Path,[object]$Value) {
    $Map[$Path]=@{Status=200;Bytes=(Get-Bytes $Value)}
}
function Add-Run([hashtable]$Map,[string]$Key,[object]$Snapshot) {
    $path="CopilotMonthlyRaw/$Key/snapshot-2026-10-20.json"
    $bytes=Get-Bytes $Snapshot
    $Map["/root:/${path}:/content"]=@{Status=200;Bytes=$bytes}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    Set-JsonResponse $Map "/root:/CopilotMonthlyRaw/$Key/publication-manifest.json:/content" @{
        schemaVersion=1;runKey=$Key;files=@(@{path=$path;sha256=$hash;length=$bytes.Length})
    }
}
function New-Map {
    $map=@{}
    Set-JsonResponse $map '/root:/CopilotMonthlyRaw:/children' @{value=@(@{name='100-1';folder=@{}},@{name='200-1';folder=@{}},@{name='300-1';folder=@{}})}
    Add-Run $map '100-1' (New-Snapshot 0)
    Add-Run $map '200-1' (New-Snapshot 5 '2026-10-28T01:00:00Z')
    $map['/root:/CopilotMonthlyRaw/300-1/publication-manifest.json:/content']=@{Status=404;Bytes=[byte[]]@()}
    $map
}
function Invoke-Restore([hashtable]$Map,[hashtable]$Overrides=@{}) {
    $script:Case++
    $parameters=@{
        OutputDirectory=(Join-Path $work "case-$script:Case")
        Months=@('2026-10');ExpectedSource='graph-beta-actions';ExpectedMetricId='all-apps-actions'
        ExpectedDateBasis='UTC/source-date';DataClass='tenant';AsOfDate='2026-10-28';GeneratedAt='2026-10-28T02:00:00Z'
    }
    foreach ($key in $Overrides.Keys) { $parameters[$key]=$Overrides[$key] }
    $request={
        param($Method,$Path,[byte[]]$Body,[hashtable]$Headers)
        if ($Method -ne 'GET' -or $Body.Length -ne 0 -or $Headers.Count -ne 0) { throw 'Unexpected request contract.' }
        if (-not $Map.ContainsKey($Path)) { throw "Unexpected path: $Path" }
        $Map[$Path]
    }.GetNewClosure()
    Restore-CopilotMonthlyHistory -Request $request @parameters
}
function Get-Manifest([hashtable]$Map) {
    [Text.Encoding]::UTF8.GetString($Map['/root:/CopilotMonthlyRaw/100-1/publication-manifest.json:/content'].Bytes) | ConvertFrom-Json -AsHashtable -DateKind String
}
function Set-Manifest([hashtable]$Map,[object]$Value) {
    Set-JsonResponse $Map '/root:/CopilotMonthlyRaw/100-1/publication-manifest.json:/content' $Value
}
try {
    [void][IO.Directory]::CreateDirectory($work)
    $env:RUNNER_TEMP=$work
    foreach ($file in @((Join-Path $root 'scripts/Copilot.History.psm1'),$PSCommandPath)) {
        $errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$null,[ref]$errors)
        Assert-True (@($errors).Count -eq 0) 'PowerShell syntax'
    }
    $map=New-Map
    $result=Invoke-Restore $map
    $payload=Get-Content -LiteralPath $result.MonthlyPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    Assert-True ($result.SnapshotCount -eq 2 -and $result.UncommittedRunKeys[0] -eq '300-1') 'Missing manifest explicitly reported, committed runs preserved'
    Assert-True ($payload.months[0].rows[0].observedCount -eq 5 -and $null -eq $payload.months[0].rows[0].count) 'Latest correction selected once, incomplete month remains null'
    $expected=Get-CopilotMonthlyPayload -Snapshots @((New-Snapshot 0),(New-Snapshot 5 '2026-10-28T01:00:00Z')) -Months @('2026-10') -AsOfDate '2026-10-28' -GeneratedAt '2026-10-28T02:00:00Z'
    Assert-True ((ConvertTo-Json -InputObject $payload -Depth 30 -Compress) -ceq (ConvertTo-Json -InputObject $expected -Depth 30 -Compress)) 'Every rebuilt monthly value equals original core payload'
    Assert-True (@(Get-ChildItem -LiteralPath $result.SnapshotDirectory -File).Count -eq 2) 'Run-date revisions persisted separately'
    $history=Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    Assert-True (-not $history.retentionVerified -and $history.historyDiscoveryComplete) 'No 90-day retention claim'
    foreach ($entry in $history.files) {
        $local=Join-Path (Split-Path $result.ManifestPath -Parent) $entry.path
        Assert-True ((Get-FileHash -LiteralPath $local).Hash.ToLowerInvariant() -ceq $entry.sha256) 'Saved original bytes match manifest'
    }
    $one=Invoke-Restore (New-Map) @{RunKeys=@('100-1')}
    $p=Get-Content -LiteralPath $one.MonthlyPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    Assert-True ($p.months[0].rows[0].knownDays -eq 1 -and $p.months[0].rows[0].observedCount -eq 0) 'Explicit observed zero is a known day'
    $map=New-Map; Add-Run $map '100-1' (New-Snapshot $null)
    $one=Invoke-Restore $map @{RunKeys=@('100-1')}
    $p=Get-Content -LiteralPath $one.MonthlyPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    Assert-True ($p.months[0].rows[0].knownDays -eq 0 -and $p.months[0].rows[0].unknownDays -eq 31) 'Null is unknown, not zero'
    $map=New-Map; Add-Run $map '200-1' (New-Snapshot 0)
    $duplicate=Invoke-Restore $map
    $p=Get-Content -LiteralPath $duplicate.MonthlyPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    Assert-True ($p.months[0].rows[0].knownDays -eq 1 -and $duplicate.SnapshotCount -eq 2) 'Same-date same-content across runs preserved but never counted twice'
    $map=New-Map; Add-Run $map '200-1' (New-Snapshot 8)
    Assert-Throws { Invoke-Restore $map } 'Conflicting duplicate'
    $map=New-Map
    $map['/root:/CopilotMonthlyRaw/100-1/snapshot-2026-10-20.json:/content'].Bytes=[byte[]]@(1,2,3)
    Assert-Throws { Invoke-Restore $map } 'hash or length'
    $map=New-Map; $manifest=Get-Manifest $map; $manifest.files[0].sha256=('0'*64); Set-Manifest $map $manifest
    Assert-Throws { Invoke-Restore $map } 'hash or length'
    foreach ($target in @('/root:/CopilotMonthlyRaw:/children','/root:/CopilotMonthlyRaw/100-1/publication-manifest.json:/content','/root:/CopilotMonthlyRaw/100-1/snapshot-2026-10-20.json:/content')) {
        $map=New-Map; $map[$target]=@{Status=403;Bytes=[byte[]]@()}
        Assert-Throws { Invoke-Restore $map } 'HTTP 403'
    }
    $map=New-Map; $map['/root:/CopilotMonthlyRaw/100-1/snapshot-2026-10-20.json:/content']=@{Status=404;Bytes=[byte[]]@()}
    Assert-Throws { Invoke-Restore $map } 'HTTP 404'
    $map=New-Map
    Set-JsonResponse $map '/root:/CopilotMonthlyRaw:/children' @{value=@();'@odata.nextLink'='https://invalid.example/next'}
    Assert-Throws { Invoke-Restore $map } 'pagination'
    Assert-Throws { Invoke-Restore (New-Map) @{MaxRuns=2} } 'run limit'
    foreach ($path in @('CopilotMonthlyRaw/200-1/snapshot-2026-10-20.json','CopilotMonthlyRaw/100-1/../secret.json','https://invalid.example/a.json','CopilotMonthlyRaw/100-1/%2e%2e.json')) {
        $map=New-Map; $manifest=Get-Manifest $map; $manifest.files[0].path=$path; Set-Manifest $map $manifest
        Assert-Throws { Invoke-Restore $map } 'manifest path'
    }
    $map=New-Map; $manifest=Get-Manifest $map; $manifest.files+=@($manifest.files[0]); Set-Manifest $map $manifest
    Assert-Throws { Invoke-Restore $map } 'Duplicate publication'
    $map=New-Map
    Set-JsonResponse $map '/root:/CopilotMonthlyRaw:/children' @{value=@(@{name='100-1';folder=@{}},@{name='100-1';folder=@{}})}
    Assert-Throws { Invoke-Restore $map } 'Duplicate history'
    $map=New-Map; $manifest=Get-Manifest $map; $manifest.runKey='200-1'; Set-Manifest $map $manifest
    Assert-Throws { Invoke-Restore $map } 'manifest schema or runKey'
    $map=New-Map; $manifest=Get-Manifest $map; $manifest.schemaVersion=2; Set-Manifest $map $manifest
    Assert-Throws { Invoke-Restore $map } 'manifest schema'
    foreach ($field in @('source','metricId','dateBasis','selectedDate','dataClass')) {
        $map=New-Map; $snapshot=New-Snapshot; $snapshot[$field]='forged'; Add-Run $map '100-1' $snapshot
        Assert-Throws { Invoke-Restore $map } 'provenance or selectedDate'
    }
    $map=New-Map; $snapshot=New-Snapshot; $snapshot.users[0].count=-1; Add-Run $map '100-1' $snapshot
    Assert-Throws { Invoke-Restore $map } 'Invalid count'
    $map=New-Map
    Assert-Throws { Invoke-Restore $map @{RunKeys=@('300-1')} } 'No committed snapshots; uncommitted runs: 300-1'
    Assert-Throws { Invoke-Restore $map @{RunKeys=@('999-1')} } 'Requested run is absent'
    Assert-Throws { Invoke-Restore $map @{RunKeys=@('100-1','100-1')} } 'unique'
    Assert-Throws { Invoke-Restore $map @{OutputDirectory=(Split-Path $one.ManifestPath -Parent)} } 'must not exist'
    Assert-Throws { Invoke-Restore $map @{OutputDirectory=(Join-Path $root 'exports\history-forbidden')} } 'requires workspace'
    $map=New-Map
    $map['/root:/CopilotMonthlyRaw:/children']=@{Status=200;Bytes=[Text.Encoding]::UTF8.GetBytes('[]')}
    Assert-Throws { Invoke-Restore $map } 'JSON must be an object'
    Assert-True (@(Get-ChildItem -LiteralPath $work -Directory).Count -eq 4) 'Failed validation creates no output directories'
    $map=New-Map
    Set-JsonResponse $map '/root:/CopilotMonthlyRaw:/children' @{value=@(
        @{name='100-1';folder=@{}},@{name='repo-12345-100-1';folder=@{}}
    )}
    Add-Run $map 'repo-12345-100-1' (New-Snapshot 0)
    $mixed=Invoke-Restore $map
    $p=Get-Content -LiteralPath $mixed.MonthlyPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    Assert-True ($mixed.SnapshotCount -eq 2 -and $p.months[0].rows[0].knownDays -eq 1) 'Legacy and repo-ID namespaces restore together without duplicate days'
    foreach ($badKey in @('repo-0-100-1','repo-name-100-1','repo-12345-100-0','repo-12345-../100-1')) {
        Set-JsonResponse $map '/root:/CopilotMonthlyRaw:/children' @{value=@(@{name=$badKey;folder=@{}})}
        Assert-Throws { Invoke-Restore $map } 'Invalid history run folder'
    }
    Write-Output "PASS: $script:Assertions assertions (transport fixtures only; no live SPO history or retention verified)"
} finally {
    $env:RUNNER_TEMP=$oldRunner
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
