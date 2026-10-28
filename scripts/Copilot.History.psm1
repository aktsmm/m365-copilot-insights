#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Copilot.Calendar.psm1')

function Read-HistoryResponse {
    param([scriptblock]$Request, [string]$Path, [switch]$AllowMissing)
    $response = & $Request 'GET' $Path ([byte[]]@()) @{}
    if ($response -isnot [Collections.IDictionary] -or -not $response.Contains('Status') -or
        -not $response.Contains('Bytes') -or $response.Status -isnot [int] -or $response.Bytes -isnot [byte[]]) {
        throw 'Invalid history transport response.'
    }
    if ($AllowMissing -and $response.Status -eq 404) { return $response }
    if ($response.Status -ne 200) { throw "History GET failed: HTTP $($response.Status): $Path" }
    $response
}

function ConvertFrom-HistoryJson([byte[]]$Bytes) {
    $text = [Text.UTF8Encoding]::new($false,$true).GetString($Bytes).TrimStart([char]0xfeff)
    $value = ConvertFrom-Json -InputObject $text -AsHashtable -DateKind String
    if ($value -isnot [Collections.IDictionary]) { throw 'History JSON must be an object.' }
    $value
}

function Assert-HistoryOutput([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '(^|[\\/])\.\.([\\/]|$)') { throw 'Unsafe history output path.' }
    $full = [IO.Path]::GetFullPath($Path)
    $workspace = Split-Path $PSScriptRoot -Parent
    $allowed = $false
    foreach ($root in @((Join-Path $workspace '.local'),$env:RUNNER_TEMP)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $base = [IO.Path]::GetFullPath($root).TrimEnd('\','/')
        if ($full.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { $allowed=$true }
    }
    if (-not $allowed) { throw 'History output requires workspace .local or RUNNER_TEMP.' }
    $ancestor=$full
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            if (((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'History output reparse point is forbidden.' }
        }
        $ancestor=Split-Path $ancestor -Parent
    }
    if (Test-Path -LiteralPath $full) { throw 'History output directory must not exist.' }
    $full
}

function Restore-CopilotMonthlyHistory {
    <#
    .SYNOPSIS
    Validates committed snapshot bytes and rebuilds calendar data without network-specific authentication.
    .DESCRIPTION
    Request receives method, drive-relative path, byte[] body, hashtable headers;
    returns @{Status=[int];Bytes=[byte[]]}. RunKeys optionally limits the selected
    runs, not discovery. Missing manifests are explicitly reported as uncommitted.
    No retention duration or tenant acquisition success is inferred.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Request,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string[]]$Months,
        [Parameter(Mandatory)][string]$ExpectedSource,
        [Parameter(Mandatory)][string]$ExpectedMetricId,
        [Parameter(Mandatory)][string]$ExpectedDateBasis,
        [Parameter(Mandatory)][ValidateSet('tenant','synthetic')][string]$DataClass,
        [Parameter(Mandatory)][string]$AsOfDate,
        [Parameter(Mandatory)][string]$GeneratedAt,
        [ValidateRange(1,1000)][int]$MaxRuns=100,
        [string[]]$RunKeys
    )
    $directory=Assert-HistoryOutput $OutputDirectory
    foreach ($value in @($ExpectedSource,$ExpectedMetricId,$ExpectedDateBasis)) {
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'Expected source, metric and date basis must be explicit.' }
    }
    $listing=ConvertFrom-HistoryJson (Read-HistoryResponse $Request '/root:/CopilotMonthlyRaw:/children').Bytes
    if ($listing.Contains('@odata.nextLink')) { throw 'History pagination unsupported; discovery is incomplete.' }
    if (-not $listing.Contains('value') -or $listing.value -isnot [array]) { throw 'Invalid history children schema.' }
    if ($listing.value.Count -gt $MaxRuns) { throw "History run limit $MaxRuns exceeded; discovery is incomplete." }
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $listing.value) {
        if ($item -isnot [Collections.IDictionary] -or -not $item.Contains('name') -or -not $item.Contains('folder') -or
            $item.name -isnot [string] -or $item.name -cnotmatch '^(?:repo-[1-9][0-9]*-)?[1-9][0-9]*-[1-9][0-9]*$') { throw 'Invalid history run folder.' }
        if (-not $names.Add($item.name)) { throw 'Duplicate history run folder.' }
    }
    if ($PSBoundParameters.ContainsKey('RunKeys')) {
        if ($RunKeys.Count -eq 0 -or @($RunKeys | Select-Object -Unique).Count -ne $RunKeys.Count) { throw 'RunKeys must be nonempty and unique.' }
        foreach ($key in $RunKeys) { if (-not $names.Contains($key)) { throw "Requested run is absent: $key" } }
        $selected=@($RunKeys | Sort-Object)
    } else { $selected=@($names | Sort-Object) }
    $uncommitted=[Collections.Generic.List[string]]::new()
    $committed=[Collections.Generic.List[string]]::new()
    $documents=[Collections.Generic.List[object]]::new()
    $snapshots=[Collections.Generic.List[object]]::new()
    foreach ($key in $selected) {
        $response=Read-HistoryResponse $Request "/root:/CopilotMonthlyRaw/$key/publication-manifest.json:/content" -AllowMissing
        if ($response.Status -eq 404) { $uncommitted.Add($key); continue }
        $manifest=ConvertFrom-HistoryJson $response.Bytes
        if (-not $manifest.Contains('schemaVersion') -or $manifest.schemaVersion -isnot [long] -or $manifest.schemaVersion -ne 1 -or
            -not $manifest.Contains('runKey') -or $manifest.runKey -cne $key -or
            -not $manifest.Contains('files') -or $manifest.files -isnot [array] -or $manifest.files.Count -eq 0) { throw 'Invalid publication manifest schema or runKey.' }
        $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $runSnapshots=0
        foreach ($entry in $manifest.files) {
            if ($entry -isnot [Collections.IDictionary] -or -not $entry.Contains('path') -or -not $entry.Contains('sha256') -or -not $entry.Contains('length') -or
                $entry.path -isnot [string] -or $entry.sha256 -isnot [string] -or $entry.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
                ($entry.length -isnot [long] -and $entry.length -isnot [int]) -or $entry.length -lt 0) { throw 'Invalid publication file schema.' }
            if ($entry.path -cnotmatch ('^(?:CopilotMonthlyRaw|CopilotMonthly)/'+[regex]::Escape($key)+'/[A-Za-z0-9][A-Za-z0-9._-]*\.(?:json|csv|html)$') -or
                $entry.path.Contains('..')) { throw 'Unsafe or cross-run manifest path.' }
            if ($entry.path -match '/snapshot-' -and $entry.path -cnotmatch ('^CopilotMonthlyRaw/'+[regex]::Escape($key)+'/snapshot-\d{4}-\d{2}-\d{2}\.json$')) {
                throw 'Invalid snapshot manifest path.'
            }
            if (-not $paths.Add($entry.path)) { throw 'Duplicate publication file path.' }
        }
        foreach ($entry in $manifest.files) {
            if ($entry.path -cnotmatch ('^CopilotMonthlyRaw/'+[regex]::Escape($key)+'/snapshot-(\d{4}-\d{2}-\d{2})\.json$')) { continue }
            $date=$Matches[1]
            $download=Read-HistoryResponse $Request "/root:/$($entry.path):/content"
            $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($download.Bytes)).ToLowerInvariant()
            if ($download.Bytes.LongLength -ne $entry.length -or $digest -cne $entry.sha256) { throw 'Snapshot hash or length mismatch.' }
            $snapshot=ConvertFrom-HistoryJson $download.Bytes
            foreach ($field in @('source','metricId','dateBasis','dataClass','selectedDate')) {
                if (-not $snapshot.Contains($field)) { throw "Snapshot missing $field." }
            }
            if ($snapshot.source -cne $ExpectedSource -or $snapshot.metricId -cne $ExpectedMetricId -or
                $snapshot.dateBasis -cne $ExpectedDateBasis -or $snapshot.dataClass -cne $DataClass -or $snapshot.selectedDate -cne $date) {
                throw 'Snapshot provenance or selectedDate mismatch.'
            }
            $snapshots.Add($snapshot)
            $documents.Add(@{name="$key-snapshot-$date.json"; bytes=$download.Bytes; sourcePath=$entry.path; sha256=$digest; length=$download.Bytes.Length})
            $runSnapshots++
        }
        if ($runSnapshots -eq 0) { throw "Committed run has no snapshots: $key" }
        $committed.Add($key)
    }
    if ($snapshots.Count -eq 0) { throw "No committed snapshots; uncommitted runs: $($uncommitted -join ',')" }
    # Validate all content before creating any output; the core handles revisions and conflicts.
    $parameters=@{Months=$Months;AsOfDate=$AsOfDate;GeneratedAt=$GeneratedAt}
    [void](Get-CopilotMonthlyPayload -Snapshots @($snapshots) @parameters)
    $snapshotDirectory=Join-Path $directory 'snapshots'
    [void][IO.Directory]::CreateDirectory($snapshotDirectory)
    foreach ($document in $documents) { [IO.File]::WriteAllBytes((Join-Path $snapshotDirectory $document.name),$document.bytes) }
    $payload=Get-CopilotMonthlyPayload -Snapshots @(Read-CopilotDailySnapshots $snapshotDirectory) @parameters
    [void](Export-CopilotMonthly -Payload $payload -OutputDirectory (Join-Path $directory 'monthly'))
    $report=[ordered]@{
        schemaVersion=1; status='rebuilt'; historyDiscoveryComplete=$true
        selectedRunKeys=$selected; committedRunKeys=@($committed); uncommittedRunKeys=@($uncommitted)
        snapshotCount=$documents.Count; retentionVerified=$false
        files=@($documents | ForEach-Object { [ordered]@{path=('snapshots/'+$_.name);sourcePath=$_.sourcePath;sha256=$_.sha256;length=$_.length} })
    }
    [IO.File]::WriteAllText((Join-Path $directory 'history-manifest.json'),(ConvertTo-Json -InputObject $report -Depth 15)+"`n",[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{Status='rebuilt';SnapshotDirectory=$snapshotDirectory;MonthlyPath=(Join-Path $directory 'monthly\monthly.json');ManifestPath=(Join-Path $directory 'history-manifest.json');UncommittedRunKeys=@($uncommitted);SnapshotCount=$documents.Count}
}

Export-ModuleMember -Function Restore-CopilotMonthlyHistory
