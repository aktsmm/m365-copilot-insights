#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [Parameter(Mandatory)][string]$EvidencePath,
    [string]$HistorySnapshotsPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$probe = Join-Path $ArtifactDirectory 'calendar-probe'
$monthly = Get-Content (Join-Path $ArtifactDirectory 'calendar-monthly\monthly.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
$summary = Get-Content (Join-Path $probe 'probe-summary.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
$directory = Get-Content (Join-Path $probe 'users.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
$stable = @(Import-Csv (Join-Path $probe 'usage-D28.csv') -Encoding utf8)
$assertions = 0
function Assert-Probe([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
function Assert-IntegerCount([object]$Value) {
    if ($null -ne $Value -and (($Value -isnot [long] -and $Value -isnot [int]) -or $Value -lt 0 -or $Value -gt 9007199254740991L)) {
        throw 'Invalid source count; expected nonnegative safe integer or explicit null.'
    }
}
function Get-VerifierMonths([string]$RefreshDate) {
    $d = [datetime]::ParseExact($RefreshDate, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    @($d.AddDays(-7).ToString('yyyy-MM'), $d.ToString('yyyy-MM')) | Select-Object -Unique
}
function Read-SourceDate([object]$Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}$') { throw 'Invalid snapshot date.' }
    [datetime]::ParseExact($Value,'yyyy-MM-dd',[cultureinfo]::InvariantCulture)
}
function Read-SourceTime([object]$Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') { throw 'Invalid snapshot timestamp.' }
    [datetimeoffset]::Parse($Value,[cultureinfo]::InvariantCulture)
}
$observations = [Collections.Generic.List[object]]::new()
Assert-Probe ($summary.runtimeApplicationVerified) 'Application provenance failed.'
Assert-Probe ($stable.Count -gt 0 -and $summary.days.Count -eq 8) 'Unexpected source coverage.'
$people = @{}
foreach ($person in $directory.value) {
    $upn=$person.userPrincipalName.ToLowerInvariant()
    if ($people.ContainsKey($upn)) { throw 'Directory roster contains duplicates.' }
    $people[$upn] = $person
}
$expected = @{}
foreach ($person in $stable) { $expected[$person.'User Principal Name'.ToLowerInvariant()] = @{ knownDays = 0; actions = [long]0 } }
Assert-Probe ($expected.Count -eq $stable.Count) 'Stable roster contains duplicates.'
$days = @(
    foreach ($day in $summary.days) {
        if ($day.status -ne 200) {
            # A failed day is an explicit unknown: it must not leave any data behind and is never counted as zero.
            Assert-Probe (-not (Test-Path (Join-Path $probe "raw-$($day.date).json")) -and -not (Test-Path (Join-Path $probe "snapshots\$($day.date).json")) -and -not [string]::IsNullOrWhiteSpace([string]$day.errorCode)) 'A failed daily request must leave no data and record its error code.'
            continue
        }
        Assert-Probe ($day.fields -is [array]) 'Daily field metadata must remain an array, including empty results.'
        $raw = Get-Content (Join-Path $probe "raw-$($day.date).json") -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
        $snapshot = Get-Content (Join-Path $probe "snapshots\$($day.date).json") -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
        $observations.Add($snapshot)
        Assert-Probe ($snapshot.metricId -cin @('all-apps-actions','all-apps-prompts') -and $snapshot.source -eq $summary.source) 'Snapshot metric drift.'
        $countKey = if ($snapshot.metricId -ceq 'all-apps-prompts') { 'allAppsCopilotPromptCount' } else { 'allAppsCopilotActionCount' }
        Assert-Probe ($snapshot.users.Count -eq $stable.Count) 'Snapshot lost the expected roster.'
        Assert-Probe ($snapshot.selectedDate -eq $day.date -and $snapshot.dateBasis -eq 'UTC') 'Snapshot date drift.'
        Assert-Probe ($day.rows -eq $raw.value.Count) 'Summary does not match the source row count.'
        $rawIndex = @{}
        $dayTotal = [long]0
        foreach ($row in $raw.value) {
            $upn = $row.userPrincipalName.ToLowerInvariant()
            Assert-Probe ($expected.ContainsKey($upn) -and -not $rawIndex.ContainsKey($upn)) 'Unexpected or duplicated daily identity.'
            Assert-Probe ($row.reportSelectedDate -eq $day.date -and $row.reportRefreshDate -eq $summary.reportRefreshDate) 'Source date mismatch.'
            if (-not $row.Contains($countKey)) { throw 'Source count property is absent.' }
            Assert-IntegerCount $row[$countKey]
            $rawIndex[$upn] = $row
            if ($null -ne $row[$countKey]) { $dayTotal += [long]$row[$countKey] }
        }
        foreach ($row in $snapshot.users) {
            $upn = $row.upn.ToLowerInvariant()
            Assert-Probe ($expected.ContainsKey($upn) -and $row.userId -eq $people[$upn].id) 'Directory identity join mismatch.'
            if ($rawIndex.ContainsKey($upn)) {
                $count = $rawIndex[$upn][$countKey]
                Assert-Probe ($row.count -ceq $count) 'Daily source value was changed.'
            } else {
                Assert-Probe ($null -eq $row.count) 'An unreported person was converted to zero.'
            }
        }
        [pscustomobject]@{
            date = $day.date
            sourceRows = $raw.value.Count
            snapshotRows = $snapshot.users.Count
            metricId = $snapshot.metricId
            sourceCount = $dayTotal
        }
    }
)
$expectedMonths = @(Get-VerifierMonths $summary.reportRefreshDate)
$entryMetrics = @($monthly.months | ForEach-Object { $_.metricId } | Select-Object -Unique)
Assert-Probe ($entryMetrics.Count -gt 0 -and @($entryMetrics | Where-Object { $_ -cnotin @('all-apps-actions','all-apps-prompts') }).Count -eq 0) 'Unexpected monthly metric.'
$entryMonths = @($monthly.months | ForEach-Object { $_.month } | Select-Object -Unique)
Assert-Probe ($summary.reportRefreshDate.Substring(0,7) -cin $entryMonths -and @($entryMonths | Where-Object { $_ -cnotin $expectedMonths }).Count -eq 0) 'Monthly date mismatch.'
Assert-Probe ($monthly.months.Count -eq ($entryMonths.Count * $entryMetrics.Count)) 'Expected every month and metric exactly once.'
$historyCount=0
if ($PSBoundParameters.ContainsKey('HistorySnapshotsPath')) {
    if (-not (Test-Path -LiteralPath $HistorySnapshotsPath -PathType Container)) { throw 'HistorySnapshotsPath must be an existing snapshots directory.' }
    $historyFiles=@(Get-ChildItem -LiteralPath $HistorySnapshotsPath -File -Filter '*.json' | Sort-Object Name)
    foreach ($file in $historyFiles) {
        $observations.Add((Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -DateKind String))
        $historyCount++
    }
}
$asOf=(Read-SourceTime $monthly.generatedAt).UtcDateTime.Date
$latestByMetric=@{}
$revisions=@{}
$templates=@{}
foreach ($snapshot in $observations) {
    if ($snapshot -isnot [Collections.IDictionary]) { throw 'Snapshot must be an object.' }
    $fields=@('schemaVersion','dataClass','source','metricId','metricLabelJa','metricLabelEn','dateBasis','selectedDate','reportRefreshDate','collectedAt','collectionComplete','users')
    if ($snapshot.Count -ne $fields.Count) { throw 'Unexpected snapshot schema.' }
    foreach ($field in $fields) { if (-not $snapshot.Contains($field)) { throw "Snapshot missing $field." } }
    foreach ($field in @('source','metricId','metricLabelJa','metricLabelEn','dateBasis','dataClass')) {
        if ($snapshot[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($snapshot[$field])) { throw 'Invalid snapshot provenance text.' }
    }
    $metricKey=$snapshot.metricId
    if ($metricKey -cnotin @('all-apps-actions','all-apps-prompts')) { throw 'History/current snapshot provenance mismatch.' }
    if (-not $templates.ContainsKey($metricKey)) { $templates[$metricKey]=$snapshot }
    $currentTemplate=$templates[$metricKey]
    if (($snapshot.schemaVersion -isnot [int] -and $snapshot.schemaVersion -isnot [long]) -or $snapshot.schemaVersion -ne 1 -or
        $snapshot.source -cne $summary.source -or
        $snapshot.dateBasis -cne 'UTC' -or $snapshot.dataClass -cne 'tenant' -or
        $snapshot.metricLabelJa -cne $currentTemplate.metricLabelJa -or $snapshot.metricLabelEn -cne $currentTemplate.metricLabelEn) {
        throw 'History/current snapshot provenance mismatch.'
    }
    $date=Read-SourceDate $snapshot.selectedDate
    $refresh=Read-SourceDate $snapshot.reportRefreshDate
    $time=Read-SourceTime $snapshot.collectedAt
    if ($date -gt $refresh -or $refresh -gt $time.UtcDateTime.Date -or $time.UtcDateTime.Date -gt $asOf) { throw 'Snapshot date/refresh inconsistency.' }
    if ($snapshot.collectionComplete -isnot [bool] -or $snapshot.users -isnot [array] -or $snapshot.users.Count -ne $stable.Count) { throw 'Snapshot roster/completeness mismatch.' }
    $seen=@{}
    $canonicalUsers=@(foreach ($row in $snapshot.users) {
        if ($row -isnot [Collections.IDictionary] -or $row.Count -ne 5) { throw 'Invalid snapshot user schema.' }
        foreach ($field in @('userId','upn','displayName','department','count')) { if (-not $row.Contains($field)) { throw "Snapshot user missing $field." } }
        foreach ($field in @('userId','upn','displayName','department')) { if ($row[$field] -isnot [string]) { throw 'Invalid snapshot user text.' } }
        $upn=$row.upn.ToLowerInvariant()
        if (-not $expected.ContainsKey($upn) -or -not $people.ContainsKey($upn) -or $row.userId -cne $people[$upn].id -or $seen.ContainsKey($upn)) { throw 'History/current roster identity mismatch.' }
        $seen[$upn]=$true
        Assert-IntegerCount $row.count
        [ordered]@{userId=$row.userId;upn=$row.upn;displayName=$row.displayName;department=$row.department;count=$row.count}
    })
    $canonical=[ordered]@{}
    foreach ($field in $fields | Where-Object { $_ -notin @('users','collectedAt') }) { $canonical[$field]=$snapshot[$field] }
    $canonical.collectedAt=$time.ToUniversalTime().ToString('o')
    $canonical.users=@($canonicalUsers | Sort-Object -Property { $_.userId } -CaseSensitive -Culture en-US)
    $signature=ConvertTo-Json -InputObject $canonical -Depth 15 -Compress
    $revisionKey="$metricKey|$($snapshot.selectedDate)|$($canonical.collectedAt)"
    if ($revisions.ContainsKey($revisionKey) -and $revisions[$revisionKey] -cne $signature) { throw 'Conflicting duplicate snapshot timestamp.' }
    $revisions[$revisionKey]=$signature
    if (-not $latestByMetric.ContainsKey($metricKey)) { $latestByMetric[$metricKey]=@{} }
    $bucket=$latestByMetric[$metricKey]
    $key=$snapshot.selectedDate
    if (-not $bucket.ContainsKey($key) -or $time -gt (Read-SourceTime $bucket[$key].collectedAt)) { $bucket[$key]=$snapshot }
}
$entrySummaries=[Collections.Generic.List[object]]::new()
foreach ($month in $monthly.months) {
    Assert-Probe ($month.source -eq $summary.source -and $latestByMetric.ContainsKey($month.metricId)) 'Monthly metric was mislabelled.'
    $latest=$latestByMetric[$month.metricId]
    $monthStart = [DateTime]::ParseExact("$($month.month)-01", 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $monthDays = [DateTime]::DaysInMonth($monthStart.Year, $monthStart.Month)
    Assert-Probe ($month.coverage.expectedDates.Count -eq $monthDays) 'Calendar month was replaced by a rolling period.'
    Assert-Probe ($month.rows.Count -eq $stable.Count) 'Monthly roster mismatch.'
    $totals=@{}
    foreach ($person in $stable) { $totals[$person.'User Principal Name'.ToLowerInvariant()] = @{ knownDays = 0; actions = [long]0 } }
    $expectedDates=@(0..($monthDays-1) | ForEach-Object { $monthStart.AddDays($_).ToString('yyyy-MM-dd') })
    $available=@($expectedDates | Where-Object { $latest.ContainsKey($_) -and $latest[$_].collectionComplete })
    $missing=@($expectedDates | Where-Object { $_ -cnotin $available })
    if (($month.coverage.expectedDates -join ',') -cne ($expectedDates -join ',') -or
        ($month.coverage.availableDates -join ',') -cne ($available -join ',') -or
        ($month.coverage.missingDates -join ',') -cne ($missing -join ',')) { throw 'Monthly coverage does not match independently selected history/current dates.' }
    foreach ($date in $available) {
        foreach ($row in $latest[$date].users) {
            if ($null -ne $row.count) {
                $source=$totals[$row.upn.ToLowerInvariant()]
                if ($source.actions -gt (9007199254740991L-$row.count)) { throw 'Monthly safe integer overflow.' }
                $source.actions += $row.count
                $source.knownDays++
            }
        }
    }
    $rowSeen=@{}
    foreach ($row in $month.rows) {
        $upn=$row.upn.ToLowerInvariant()
        if (-not $totals.ContainsKey($upn) -or $rowSeen.ContainsKey($upn) -or $row.userId -cne $people[$upn].id) { throw 'Monthly roster identity mismatch.' }
        $rowSeen[$upn]=$true
        $source = $totals[$upn]
        foreach ($field in @('count','observedCount','knownDays','unknownDays')) {
            if (-not $row.Contains($field)) { throw "Monthly row missing $field." }
            Assert-IntegerCount $row[$field]
            if ($field -ne 'count' -and $null -eq $row[$field]) { throw "Monthly row $field cannot be null." }
        }
        Assert-Probe ($row.observedCount -eq $source.actions -and $row.knownDays -eq $source.knownDays) 'Monthly values do not match raw daily evidence.'
        Assert-Probe ($row.unknownDays -eq ($monthDays - $source.knownDays)) 'Unknown-day accounting mismatch.'
        if ($source.knownDays -lt $monthDays -or $monthStart.AddMonths(1) -gt $asOf) {
            Assert-Probe ($null -eq $row.count -and $row.status -eq 'unknown') 'Incomplete data was exposed as a confirmed monthly total.'
        } elseif ($row.count -cne $source.actions -or $row.status -cne 'known') {
            throw 'Complete row count/status mismatch.'
        }
    }
    $expectedStatus=if ($monthStart.AddMonths(1) -gt $asOf) { 'in-progress' } elseif ($missing.Count -or @($totals.Values | Where-Object { $_.knownDays -lt $monthDays }).Count) { 'partial' } else { 'complete' }
    if ($month.coverage.status -cne $expectedStatus) { throw 'Monthly coverage status mismatch.' }
    $entrySummaries.Add([pscustomobject]@{ metricId = $month.metricId; month = $month.month; calendarDays = $monthDays; coverageStatus = $month.coverage.status
        knownMonthlyUsers = @($month.rows | Where-Object status -eq 'known').Count; unknownMonthlyUsers = @($month.rows | Where-Object status -eq 'unknown').Count })
}$evidence = @{
    observedAt = [DateTime]::UtcNow.ToString('o')
    assertions = $assertions
    metricIds = @($entryMetrics)
    months = @($entrySummaries)
    roster = $stable.Count
    rawDailyTotals = @($days | Group-Object metricId | ForEach-Object { [ordered]@{ metricId = $_.Name; total = ($_.Group | Measure-Object sourceCount -Sum).Sum } })
    days = $days
    historySnapshotCount = $historyCount
    historyEvidenceBoundary = 'History snapshots were validated by the preceding Restore operation (SHA256/length/schema/provenance). This verifier rechecks schema/provenance/roster and independently aggregates snapshots; historical raw responses are not re-reconciled here.'
    currentRawReconciled = $true
    historicalRawReconciled = $false
    aggregationAsOfDate = $asOf.ToString('yyyy-MM-dd')
    aggregationAsOfBasis = 'UTC date of supplied monthly.generatedAt; integration must use the same AsOfDate for build and verification.'
}
if (Test-Path -LiteralPath $EvidencePath) { throw 'Evidence output must not overwrite an existing artifact.' }
[IO.File]::WriteAllText([IO.Path]::GetFullPath($EvidencePath), ($evidence | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$evidence | ConvertTo-Json -Depth 10
