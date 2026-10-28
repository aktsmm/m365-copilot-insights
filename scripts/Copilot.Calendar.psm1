#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:WorkspaceRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent

function Get-CalendarHash([string]$Text) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Read-CalendarDate([object]$Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}$') { throw 'Invalid calendar date.' }
    try { [datetime]::ParseExact($Value, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
    catch { throw 'Invalid calendar date.' }
}

function Read-CalendarTimestamp([object]$Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
        throw 'Invalid ISO timestamp; timezone is required.'
    }
    try { [datetimeoffset]::Parse($Value, [cultureinfo]::InvariantCulture) }
    catch { throw 'Invalid ISO timestamp.' }
}

function Assert-CalendarFields([Collections.IDictionary]$Object, [string[]]$Fields) {
    foreach ($field in $Fields) {
        if (-not $Object.Contains($field)) { throw "Missing property: $field" }
    }
    foreach ($field in $Object.Keys) {
        if ($field -cnotin $Fields) { throw "Unexpected property: $field" }
    }
}

function ConvertTo-CalendarSnapshot {
    param([Parameter(Mandatory)][Collections.IDictionary]$Snapshot, [Parameter(Mandatory)][string]$AsOfDate)
    Assert-CalendarFields $Snapshot @('schemaVersion','dataClass','source','metricId','metricLabelJa','metricLabelEn','dateBasis','selectedDate','reportRefreshDate','collectedAt','collectionComplete','users')
    if ($Snapshot.schemaVersion -isnot [long] -and $Snapshot.schemaVersion -isnot [int]) { throw 'Invalid schemaVersion.' }
    if ($Snapshot.schemaVersion -ne 1) { throw 'Unsupported schemaVersion.' }
    if ($Snapshot.dataClass -cnotin @('tenant','synthetic')) { throw 'Invalid dataClass.' }
    foreach ($field in @('source','metricId','metricLabelJa','metricLabelEn','dateBasis')) {
        if ($Snapshot[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot[$field])) { throw "Invalid $field." }
    }
    if ($Snapshot.metricId -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'Invalid metricId.' }
    $asOf = Read-CalendarDate $AsOfDate
    $date = Read-CalendarDate $Snapshot.selectedDate
    $refresh = Read-CalendarDate $Snapshot.reportRefreshDate
    $collected = Read-CalendarTimestamp $Snapshot.collectedAt
    if ($date -gt $asOf -or $refresh -gt $asOf -or $collected.UtcDateTime.Date -gt $asOf) { throw 'Future snapshot date.' }
    if ($date -gt $refresh -or $refresh -gt $collected.UtcDateTime.Date) { throw 'Inconsistent reportRefreshDate.' }
    if ($Snapshot.collectionComplete -isnot [bool]) { throw 'Invalid collectionComplete.' }
    if ($Snapshot.users -isnot [array] -or $Snapshot.users.Count -eq 0) { throw 'Expected nonempty complete users roster.' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $upns = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $users = foreach ($user in $Snapshot.users) {
        if ($user -isnot [Collections.IDictionary]) { throw 'Invalid user object.' }
        Assert-CalendarFields $user @('userId','upn','displayName','department','count')
        foreach ($field in @('userId','upn','displayName','department')) {
            if ($user[$field] -isnot [string]) { throw "Invalid user $field." }
        }
        if ([string]::IsNullOrWhiteSpace($user.userId) -or [string]::IsNullOrWhiteSpace($user.upn) -or
            $user.userId -cne $user.userId.Trim() -or $user.upn -cne $user.upn.Trim()) { throw 'Invalid user identity.' }
        if (-not $ids.Add($user.userId) -or -not $upns.Add($user.upn)) { throw 'Duplicate user identity.' }
        $count = $user.count
        if ($null -ne $count -and (($count -isnot [int] -and $count -isnot [long]) -or $count -lt 0 -or $count -gt 9007199254740991L)) {
            throw 'Invalid count: expected nonnegative safe integer or explicit null.'
        }
        [ordered]@{ userId=$user.userId; upn=$user.upn; displayName=$user.displayName; department=$user.department; count=$count }
    }
    $result = [ordered]@{}
    foreach ($field in @('schemaVersion','dataClass','source','metricId','metricLabelJa','metricLabelEn','dateBasis','selectedDate','reportRefreshDate')) { $result[$field] = $Snapshot[$field] }
    $result.collectedAt = $collected.ToUniversalTime().ToString('o', [cultureinfo]::InvariantCulture)
    $result.collectionComplete = $Snapshot.collectionComplete
    $result.users = @($users | Sort-Object -Property { $_.userId } -CaseSensitive -Culture en-US)
    $result
}

function Assert-CalendarPath {
    param([string]$Path, [string]$DataClass)
    if ($DataClass -cnotin @('tenant','synthetic')) { throw 'Invalid dataClass.' }
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '(^|[\\/])\.\.([\\/]|$)') { throw 'Unsafe output path.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($DataClass -eq 'tenant') {
        $allowed = $false
        foreach ($root in @((Join-Path $script:WorkspaceRoot '.local'), $env:RUNNER_TEMP)) {
            if ([string]::IsNullOrWhiteSpace($root)) { continue }
            $base = [IO.Path]::GetFullPath($root).TrimEnd('\','/')
            if ($full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true }
        }
        if (-not $allowed -or $full -match '(^|[\\/])exports([\\/]|$)') { throw 'Tenant output requires workspace .local or RUNNER_TEMP, outside exports.' }
    }
    $ancestor = $full
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            if (((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsafe reparse-point output path.' }
        }
        $ancestor = Split-Path $ancestor -Parent
    }
    $full
}

function Read-CopilotDailySnapshots {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw 'SnapshotsPath does not exist.' }
    $item = Get-Item -LiteralPath $Path
    $files = if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $Path -File -Filter '*.json' | Sort-Object Name) } else { @($item) }
    foreach ($file in $files) {
        $snapshot = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -DateKind String
        if ($snapshot -isnot [Collections.IDictionary]) { throw 'Snapshot must be a JSON object.' }
        $snapshot
    }
}

function Get-CopilotMonthlyPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Snapshots,
        [Parameter(Mandatory)][string[]]$Months,
        [string]$AsOfDate = [datetime]::UtcNow.ToString('yyyy-MM-dd'),
        [string]$GeneratedAt = [datetimeoffset]::UtcNow.ToString('o'),
        [Collections.IDictionary]$EmptyMetadata
    )
    $asOf = Read-CalendarDate $AsOfDate
    [void](Read-CalendarTimestamp $GeneratedAt)
    if ($Months.Count -eq 0 -or @($Months | Select-Object -Unique).Count -ne $Months.Count) { throw 'Months must be explicit and unique.' }
    foreach ($month in $Months) {
        if ($month -cnotmatch '^\d{4}-\d{2}$') { throw 'Invalid month.' }
        $start = Read-CalendarDate "$month-01"
        if ($start -gt $asOf -or $start.Year -eq 9999) { throw 'Future or unsupported month.' }
    }
    $all = @($Snapshots | ForEach-Object { ConvertTo-CalendarSnapshot -Snapshot $_ -AsOfDate $AsOfDate })
    $empty = $all.Count -eq 0
    if ($empty) {
        if ($null -eq $EmptyMetadata) { throw 'Empty input requires explicit EmptyMetadata and roster.' }
        # Metadata is a validated snapshot-shaped declaration, never an available observation.
        $all = @(ConvertTo-CalendarSnapshot -Snapshot $EmptyMetadata -AsOfDate $AsOfDate)
    } elseif ($null -ne $EmptyMetadata) { throw 'EmptyMetadata is only allowed with empty input.' }
    foreach ($field in @('dataClass','source','dateBasis')) {
        if (@($all | ForEach-Object { $_[$field] } | Select-Object -Unique -CaseInsensitive:$false).Count -ne 1) { throw "Mixed $field is not allowed." }
    }
    $monthsOut = [Collections.Generic.List[object]]::new()
    foreach ($group in @($all | Group-Object -Property { $_.metricId } -CaseSensitive | Sort-Object Name -CaseSensitive -Culture en-US)) {
        $records = @($group.Group)
        $meta = @($records | Sort-Object -Property { $_.collectedAt },{ $_.selectedDate } -Descending)[0]
        foreach ($field in @('metricLabelJa','metricLabelEn')) {
            if (@($records | ForEach-Object { $_[$field] } | Select-Object -Unique -CaseInsensitive:$false).Count -ne 1) { throw "Mixed $field is not allowed." }
        }
        $rosterIds = @($meta.users.userId) -join "`n"
        foreach ($record in $records) {
            if ((@($record.users.userId) -join "`n") -cne $rosterIds) { throw 'Incomplete or changed roster; explicit null rows are required.' }
        }
        $latest = @{}
        $revisions = @{}
        foreach ($record in $records) {
            $key = "$($record.selectedDate)|$($record.collectedAt)"
            $json = ConvertTo-Json -InputObject $record -Depth 20 -Compress
            if ($revisions.ContainsKey($key) -and $revisions[$key] -cne $json) { throw 'Conflicting duplicate snapshot timestamp.' }
            $revisions[$key] = $json
            $date = $record.selectedDate
            if (-not $latest.ContainsKey($date) -or [datetimeoffset]$record.collectedAt -gt [datetimeoffset]$latest[$date].collectedAt) { $latest[$date] = $record }
        }
        foreach ($month in @($Months | Sort-Object)) {
            $start = Read-CalendarDate "$month-01"
            $end = $start.AddMonths(1)
            $expected = @((0..(($end - $start).Days - 1)) | ForEach-Object { $start.AddDays($_).ToString('yyyy-MM-dd') })
            $available = @($expected | Where-Object { -not $empty -and $latest.ContainsKey($_) -and $latest[$_].collectionComplete })
            $missing = @($expected | Where-Object { $_ -cnotin $available })
            $selected = @($latest.Values | Where-Object { $_.selectedDate -ge "$month-01" -and $_.selectedDate -lt $end.ToString('yyyy-MM-dd') } | Sort-Object -Property { $_.collectedAt },{ $_.selectedDate } -Descending)
            $roster = if ($selected.Count) { $selected[0].users } else { $meta.users }
            $rows = foreach ($user in $roster) {
                [long]$observed = 0
                $known = 0
                foreach ($date in $available) {
                    $value = @($latest[$date].users | Where-Object { $_.userId -ceq $user.userId })[0].count
                    if ($null -ne $value) {
                        if ($observed -gt (9007199254740991L - $value)) { throw 'Monthly count exceeds safe integer range.' }
                        $observed += $value
                        $known++
                    }
                }
                $unknown = $expected.Count - $known
                $count = if ($unknown -eq 0 -and $end -le $asOf) { $observed } else { $null }
                [ordered]@{
                    userId=$user.userId; upn=$user.upn; displayName=$user.displayName; department=$user.department
                    count=$count; observedCount=$observed; knownDays=$known; unknownDays=$unknown
                    status=$(if ($null -eq $count) { 'unknown' } else { 'known' })
                }
            }
            $status = if ($end -gt $asOf) { 'in-progress' } elseif ($missing.Count -or @($rows | Where-Object { $_.status -eq 'unknown' }).Count) { 'partial' } else { 'complete' }
            $refresh = if (-not $empty -and $selected.Count) { @($selected.reportRefreshDate | Sort-Object -Descending)[0] } else { $null }
            $monthsOut.Add([ordered]@{
                month=$month; metricId=$meta.metricId; metricLabelJa=$meta.metricLabelJa; metricLabelEn=$meta.metricLabelEn
                dateBasis=$meta.dateBasis; source=$meta.source; reportRefreshDate=$refresh
                coverage=[ordered]@{ expectedDates=$expected; availableDates=$available; missingDates=$missing; status=$status }
                rows=@($rows | Sort-Object -Property { $_.userId } -CaseSensitive -Culture en-US)
            })
        }
    }
    [ordered]@{ schemaVersion=1; dataClass=$all[0].dataClass; generatedAt=$GeneratedAt; months=@($monthsOut | Sort-Object -Property { $_.month },{ $_.metricId } -CaseSensitive -Culture en-US) }
}

function Add-CopilotDailySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SnapshotPath,
        [Parameter(Mandatory)][string]$HistoryDirectory,
        [string]$AsOfDate = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    )
    $incoming = @(Read-CopilotDailySnapshots -Path $SnapshotPath)
    if ($incoming.Count -ne 1) { throw 'Append requires one snapshot document.' }
    $snapshot = ConvertTo-CalendarSnapshot -Snapshot $incoming[0] -AsOfDate $AsOfDate
    $directory = Assert-CalendarPath $HistoryDirectory $snapshot.dataClass
    $prior = @(if (Test-Path -LiteralPath $directory) { Read-CopilotDailySnapshots $directory })
    [void](Get-CopilotMonthlyPayload -Snapshots @($prior + @($snapshot)) -Months @($snapshot.selectedDate.Substring(0,7)) -AsOfDate $AsOfDate)
    $json = (ConvertTo-Json -InputObject $snapshot -Depth 20 -Compress) + "`n"
    $path = Join-Path $directory ((Get-CalendarHash $json) + '.json')
    [void][IO.Directory]::CreateDirectory($directory)
    if (Test-Path -LiteralPath $path) {
        if ([IO.File]::ReadAllText($path) -cne $json) { throw 'Immutable history hash conflict.' }
        return [pscustomobject]@{ added=$false; fileName=[IO.Path]::GetFileName($path) }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    [pscustomobject]@{ added=$true; fileName=[IO.Path]::GetFileName($path) }
}

function ConvertTo-CalendarCsvCell([object]$Value) {
    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($text -match '^[\s\x00-\x20]*[=+@-]|^[\t\r\n]') { $text = "'" + $text }
    '"' + $text.Replace('"','""') + '"'
}

function Export-CopilotMonthly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Payload,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    $directory = Assert-CalendarPath $OutputDirectory $Payload.dataClass
    foreach ($month in $Payload.months) {
        if ($month.month -cnotmatch '^\d{4}-\d{2}$' -or $month.metricId -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'Unsafe month or metric output name.' }
    }
    if ((Test-Path -LiteralPath $directory) -and
        (-not (Get-Item -LiteralPath $directory).PSIsContainer -or @(Get-ChildItem -LiteralPath $directory -Force).Count)) { throw 'OutputDirectory must be empty.' }
    [void][IO.Directory]::CreateDirectory($directory)
    $files = [Collections.Generic.List[object]]::new()
    $jsonPath = Join-Path $directory 'monthly.json'
    [IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject $Payload -Depth 30) + "`n", [Text.UTF8Encoding]::new($false))
    foreach ($month in $Payload.months) {
        $columns = @('month','metricId','source','dateBasis','reportRefreshDate','coverageStatus','userId','upn','displayName','department','count','observedCount','knownDays','unknownDays','status')
        $lines = [Collections.Generic.List[string]]::new()
        $lines.Add((($columns | ForEach-Object { ConvertTo-CalendarCsvCell $_ }) -join ','))
        foreach ($row in $month.rows) {
            $csv = [ordered]@{ month=$month.month; metricId=$month.metricId; source=$month.source; dateBasis=$month.dateBasis; reportRefreshDate=$month.reportRefreshDate; coverageStatus=$month.coverage.status }
            foreach ($field in @('userId','upn','displayName','department','count','observedCount','knownDays','unknownDays','status')) { $csv[$field] = $row[$field] }
            $lines.Add((($columns | ForEach-Object { ConvertTo-CalendarCsvCell $csv[$_] }) -join ','))
        }
        $name = "$($month.month)-$($month.metricId).csv"
        [IO.File]::WriteAllText((Join-Path $directory $name), ($lines -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($true))
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -File | Sort-Object Name)) {
        $files.Add([ordered]@{ path=$file.Name; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
    }
    $manifest = [ordered]@{
        schemaVersion=1; dataClass=$Payload.dataClass; generatedAt=$Payload.generatedAt
        complete=(@($Payload.months | Where-Object { $_.coverage.status -ne 'complete' }).Count -eq 0)
        months=@($Payload.months | ForEach-Object { [ordered]@{ month=$_.month; metricId=$_.metricId; status=$_.coverage.status; expectedDays=$_.coverage.expectedDates.Count; availableDays=$_.coverage.availableDates.Count; missingDays=$_.coverage.missingDates.Count } })
        files=@($files)
    }
    [IO.File]::WriteAllText((Join-Path $directory 'manifest.json'), (ConvertTo-Json -InputObject $manifest -Depth 15) + "`n", [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Status='generated'; Complete=$manifest.complete; MonthMetricCount=$Payload.months.Count; FileCount=$files.Count }
}

Export-ModuleMember -Function Read-CopilotDailySnapshots,Get-CopilotMonthlyPayload,Add-CopilotDailySnapshot,Export-CopilotMonthly
