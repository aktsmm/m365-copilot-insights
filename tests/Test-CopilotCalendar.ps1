#requires -Version 7.5
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pocRoot = Split-Path $PSScriptRoot -Parent
$module = Join-Path $pocRoot 'scripts\Copilot.Calendar.psm1'
$build = Join-Path $pocRoot 'scripts\Build-CopilotMonthly.ps1'
Import-Module $module -Force
$work = Join-Path $PSScriptRoot ('.calendar-test-' + [guid]::NewGuid().ToString('N'))
$oldRunner = $env:RUNNER_TEMP
$script:Assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
    $script:Assertions++
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught) "Expected error: $Pattern"
    Assert-True ($caught.Exception.Message -match $Pattern) "Error mismatch: $caught; expected $Pattern"
}
function New-Snapshot([string]$Date = '2024-02-01', [object]$Count = 1) {
    [ordered]@{
        schemaVersion=1; dataClass='synthetic'; source='fixture-v1'; metricId='all-apps-prompts'
        metricLabelJa='全アプリ送信プロンプト数'; metricLabelEn='All apps prompts'; dateBasis='UTC/source-date'
        selectedDate=$Date; reportRefreshDate=$Date
        collectedAt=$(if ($Date -gt '2026-10-28') { "${Date}T00:00:00Z" } else { '2026-10-28T00:00:00Z' })
        collectionComplete=$true
        users=@(
            [ordered]@{ userId='b'; upn='b@example.invalid'; displayName='B'; department='B'; count=$Count }
            [ordered]@{ userId='a'; upn='a@example.invalid'; displayName='A'; department='A'; count=0 }
        )
    }
}
function New-Month([string]$Month) {
    $start = [datetime]::ParseExact("$Month-01",'yyyy-MM-dd',[cultureinfo]::InvariantCulture)
    foreach ($day in 0..(($start.AddMonths(1)-$start).Days-1)) { New-Snapshot $start.AddDays($day).ToString('yyyy-MM-dd') }
}
function Get-Payload([object[]]$Snapshots, [string[]]$Months = @('2024-02'), [string]$AsOf = '2026-10-28') {
    Get-CopilotMonthlyPayload -Snapshots $Snapshots -Months $Months -AsOfDate $AsOf -GeneratedAt '2026-10-28T00:00:00Z'
}
function Write-Json([string]$Path, [object]$Object) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Object -Depth 20), [Text.UTF8Encoding]::new($false))
}
try {
    [void][IO.Directory]::CreateDirectory($work)
    $env:RUNNER_TEMP = $work
    foreach ($path in @($module,$build,$PSCommandPath)) {
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
        Assert-True (@($errors).Count -eq 0) "Syntax: $path"
    }
    foreach ($case in @(@('2023-02',28),@('2024-02',29),@('2024-04',30),@('2024-01',31),@('2023-12',31),@('2000-02',29),@('2100-02',28))) {
        $p = Get-Payload @(New-Month $case[0]) @($case[0]) '2101-01-01'
        $m = $p.months[0]
        Assert-True ($m.coverage.expectedDates.Count -eq $case[1] -and $m.coverage.availableDates.Count -eq $case[1]) "Exact calendar days $($case[0])"
        Assert-True ($m.coverage.status -eq 'complete' -and $m.coverage.missingDates.Count -eq 0) 'Complete historical month'
        Assert-True ($m.rows[1].count -eq $case[1] -and $m.rows[0].count -eq 0) 'Calendar sum, zero distinct'
        Assert-True ($m.rows[1].knownDays -eq $case[1] -and $m.rows[1].unknownDays -eq 0) 'Known day reconciliation'
    }
    $records = @(New-Month '2024-02')
    $correction = New-Snapshot '2024-02-01' 10
    $correction.collectedAt = '2026-10-28T01:00:00+00:00'
    $p = Get-Payload @($records + @($correction,$correction))
    Assert-True ($p.months[0].rows[1].count -eq 38) 'Latest correction upserts, not adds; exact duplicate idempotent'
    $p2 = Get-Payload @(@($correction) + @($records | Sort-Object selectedDate -Descending))
    Assert-True ((ConvertTo-Json $p -Depth 30 -Compress) -ceq (ConvertTo-Json $p2 -Depth 30 -Compress)) 'Stable ordering independent of input order'
    $conflict = New-Snapshot '2024-02-01' 11
    Assert-Throws { Get-Payload @($records + @($conflict)) } 'Conflicting duplicate'
    $conflict.collectedAt = '2026-10-28T09:00:00+09:00'
    Assert-Throws { Get-Payload @($records + @($conflict)) } 'Conflicting duplicate'
    $records[0].users[0].count = $null
    $p = Get-Payload $records
    Assert-True ($null -eq $p.months[0].rows[1].count -and $p.months[0].rows[1].observedCount -eq 28) 'Explicit null retains only observed sum'
    Assert-True ($p.months[0].coverage.status -eq 'partial' -and $p.months[0].rows[1].unknownDays -eq 1) 'Null marks partial, not complete'
    $records = @(New-Month '2024-02') | Select-Object -Skip 1
    $p = Get-Payload $records
    Assert-True ($p.months[0].coverage.missingDates[0] -eq '2024-02-01' -and $null -eq $p.months[0].rows[0].count) 'Missing day invalidates even zero user total'
    $records[0].collectionComplete = $false
    $p = Get-Payload $records
    Assert-True ($p.months[0].coverage.missingDates.Count -eq 2 -and $p.months[0].rows[1].knownDays -eq 27) 'Incomplete collection excluded from available days'
    $p = Get-Payload @((New-Snapshot '2026-10-01' 5)) @('2026-10')
    Assert-True ($p.months[0].coverage.status -eq 'in-progress' -and $p.months[0].coverage.expectedDates.Count -eq 31 -and $null -eq $p.months[0].rows[1].count) 'Current month full expected calendar, reference only'
    $p = Get-Payload @((New-Snapshot '2024-01-31' 2),(New-Snapshot '2024-02-01' 3),(New-Snapshot '2023-12-31' 4)) @('2024-02','2023-12','2024-01')
    Assert-True (($p.months.month -join ',') -ceq '2023-12,2024-01,2024-02') 'Year and month boundary stable sorting'
    Assert-True (($p.months | ForEach-Object { $_.rows[1].observedCount }) -join ',' -eq '4,2,3') 'No leakage across month boundaries'
    $actions = New-Snapshot '2024-02-01' 99
    $actions.metricId='all-apps-actions'; $actions.metricLabelJa='アクション数'; $actions.metricLabelEn='Actions'
    $p = Get-Payload @((New-Snapshot),$actions)
    Assert-True ($p.months.Count -eq 2 -and $p.months[0].rows[1].observedCount -eq 99 -and $p.months[1].rows[1].observedCount -eq 1) 'Actions and prompts separate, never aliased'
    foreach ($field in @('source','dateBasis','metricLabelJa','metricLabelEn','dataClass')) {
        $bad = New-Snapshot '2024-02-02'
        $bad[$field] = if ($field -eq 'dataClass') { 'tenant' } else { 'different' }
        Assert-Throws { Get-Payload @((New-Snapshot),$bad) } "Mixed $field"
    }
    foreach ($invalid in @(-1,1.5,'1',1.0,$true,9007199254740992L)) {
        $bad=New-Snapshot; $bad.users[0].count=$invalid
        Assert-Throws { Get-Payload @($bad) } 'Invalid count'
    }
    $bad=New-Snapshot; $bad.users[0].Remove('count')
    Assert-Throws { Get-Payload @($bad) } 'Missing property: count'
    $bad=New-Snapshot '2024-02-02'; $bad.users=@($bad.users[0])
    Assert-Throws { Get-Payload @((New-Snapshot),$bad) } 'roster'
    $bad=New-Snapshot; $bad.users=@($bad.users[0],$bad.users[0])
    Assert-Throws { Get-Payload @($bad) } 'Duplicate user'
    $bad=New-Snapshot; $bad.schemaVersion=2
    Assert-Throws { Get-Payload @($bad) } 'schemaVersion'
    $bad=New-Snapshot; $bad.collectionComplete='true'
    Assert-Throws { Get-Payload @($bad) } 'collectionComplete'
    $bad=New-Snapshot; $bad.selectedDate='2026-10-29'; $bad.reportRefreshDate='2026-10-29'
    Assert-Throws { Get-Payload @($bad) } 'Future'
    $bad=New-Snapshot; $bad.reportRefreshDate='2024-01-31'
    Assert-Throws { Get-Payload @($bad) } 'Inconsistent'
    $bad=New-Snapshot; $bad.reportRefreshDate='2026-10-28'; $bad.collectedAt='2026-10-27T23:00:00Z'
    Assert-Throws { Get-Payload @($bad) } 'Inconsistent'
    $bad=New-Snapshot; $bad.collectedAt='2026-10-28T00:00:00'
    Assert-Throws { Get-Payload @($bad) } 'timezone'
    Assert-Throws { Get-Payload @((New-Snapshot)) @('2024-13') } 'Invalid calendar'
    Assert-Throws { Get-Payload @((New-Snapshot)) @('2026-11') } 'Future'
    Assert-Throws { Get-Payload @((New-Snapshot)) @('2024-02','2024-02') } 'unique'
    Assert-Throws { Get-Payload @() } 'Empty input'
    $p=Get-CopilotMonthlyPayload -Snapshots @() -Months @('2024-02') -EmptyMetadata (New-Snapshot) -AsOfDate '2026-10-28'
    Assert-True ($p.months[0].coverage.availableDates.Count -eq 0 -and $null -eq $p.months[0].reportRefreshDate -and $null -eq $p.months[0].rows[1].count) 'Empty declaration never becomes observed success'
    $huge=@(New-Month '2024-02'); $huge[0].users[0].count=9007199254740991L
    Assert-Throws { Get-Payload $huge } 'safe integer range'
    $inputPath = Join-Path $work 'input.json'
    $history = Join-Path $work 'history'
    Write-Json $inputPath (New-Snapshot)
    $added=Add-CopilotDailySnapshot -SnapshotPath $inputPath -HistoryDirectory $history -AsOfDate '2026-10-28'
    $again=Add-CopilotDailySnapshot -SnapshotPath $inputPath -HistoryDirectory $history -AsOfDate '2026-10-28'
    Assert-True ($added.added -and -not $again.added) 'History content-addressed append is idempotent'
    $oldHash=(Get-FileHash -LiteralPath (Join-Path $history $added.fileName)).Hash
    Write-Json $inputPath $correction
    [void](Add-CopilotDailySnapshot -SnapshotPath $inputPath -HistoryDirectory $history -AsOfDate '2026-10-28')
    Assert-True (@(Get-ChildItem -LiteralPath $history -File).Count -eq 2 -and (Get-FileHash -LiteralPath (Join-Path $history $added.fileName)).Hash -eq $oldHash) 'Correction preserves immutable earlier revision'
    $conflict=New-Snapshot '2024-02-01' 8; Write-Json $inputPath $conflict
    Assert-Throws { Add-CopilotDailySnapshot -SnapshotPath $inputPath -HistoryDirectory $history -AsOfDate '2026-10-28' } 'Conflicting duplicate'
    Assert-True (@(Get-ChildItem -LiteralPath $history -File).Count -eq 2) 'Conflict writes no history'
    $bad=New-Snapshot; $bad.dataClass='tenant'
    Write-Json $inputPath $bad
    Assert-Throws { & $build -SnapshotsPath $inputPath -Months '2024-02' -OutputDirectory (Join-Path $pocRoot 'exports\calendar-forbidden') -AsOfDate '2026-10-28' } 'Tenant output'
    Assert-Throws { Add-CopilotDailySnapshot -SnapshotPath $inputPath -HistoryDirectory (Join-Path $pocRoot 'tests\calendar-forbidden') -AsOfDate '2026-10-28' } 'Tenant output'
    $bad.users[0].displayName=' =HYPERLINK("x")'; $bad.users[0].department="`t+SUM(1)"
    Write-Json $inputPath $bad
    $a=Join-Path $work 'a'; $b=Join-Path $work 'b'
    foreach ($out in @($a,$b)) { & $build -SnapshotsPath $inputPath -Months '2024-02' -OutputDirectory $out -AsOfDate '2026-10-28' -GeneratedAt '2026-10-28T02:00:00Z' | Out-Null }
    $csvPath=Join-Path $a '2024-02-all-apps-prompts.csv'
    $bytes=[IO.File]::ReadAllBytes($csvPath)
    Assert-True ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'CSV Excel UTF8 BOM'
    $csv=@(Import-Csv -LiteralPath $csvPath)
    Assert-True ($csv[1].displayName.StartsWith("' =") -and $csv[1].department.StartsWith("'`t+")) 'Formula escaping covers leading whitespace/control'
    Assert-True ($csv[1].count -eq '' -and $csv[1].observedCount -eq '1' -and $csv[1].coverageStatus -eq 'partial') 'CSV null is blank, observed reference separate'
    $manifest=Get-Content -LiteralPath (Join-Path $a 'manifest.json') -Raw | ConvertFrom-Json
    Assert-True (-not $manifest.complete -and $manifest.files.Count -eq 2 -and $manifest.months[0].missingDays -eq 28) 'Manifest completeness and only derived files'
    foreach ($file in $manifest.files) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $a $file.path)).Hash.ToLowerInvariant() -ceq $file.sha256) 'Manifest digest verified'
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $a -File)) {
        Assert-True ((Get-FileHash -LiteralPath $file.FullName).Hash -eq (Get-FileHash -LiteralPath (Join-Path $b $file.Name)).Hash) 'Byte-deterministic generated output'
    }
    Assert-Throws { & $build -SnapshotsPath $inputPath -Months '2024-02' -OutputDirectory $a -AsOfDate '2026-10-28' } 'must be empty'
    $bad.users[0].Remove('count'); Write-Json $inputPath $bad
    $invalidOut=Join-Path $work 'invalid'
    Assert-Throws { & $build -SnapshotsPath $inputPath -Months '2024-02' -OutputDirectory $invalidOut -AsOfDate '2026-10-28' } 'Missing property'
    Assert-True (-not (Test-Path -LiteralPath $invalidOut)) 'Invalid inputs produce no artifacts'
    Write-Output "PASS: $script:Assertions assertions (calendar fixtures only; no real month verified)"
} finally {
    $env:RUNNER_TEMP=$oldRunner
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
