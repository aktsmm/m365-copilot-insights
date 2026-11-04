#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-CopilotJsonBytes {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes).TrimStart([char]0xFEFF)
    return ($text | ConvertFrom-Json -AsHashtable -DateKind String)
}

function Get-CopilotBytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Test-CopilotCommentaryProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$CommentaryBytes,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Provenance,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$RunAttempt
    )
    $keys = @('schemaVersion', 'source', 'runId', 'runAttempt', 'safeOutputJobId',
        'safeOutputJobStartedAt', 'safeOutputJobCompletedAt', 'artifactId', 'artifactName',
        'artifactCreatedAt', 'artifactExpiresAt', 'commentarySha256', 'inputSha256')
    if ($Provenance.Count -ne $keys.Count -or @($keys | Where-Object { -not $Provenance.Contains($_) }).Count) {
        throw 'Invalid commentary provenance fields.'
    }
    if ($Provenance.schemaVersion -ne 1 -or $Provenance.source -cne 'safe-output-artifact' -or
        $Provenance.artifactName -cne 'commentary.json' -or
        [string]$Provenance.artifactId -notmatch '^[1-9]\d*$' -or
        [string]$Provenance.safeOutputJobId -notmatch '^[1-9]\d*$' -or
        $RunId -notmatch '^[1-9]\d*$' -or [string]$Provenance.runId -cne $RunId -or
        $RunAttempt -lt 1 -or $Provenance.runAttempt -ne $RunAttempt) {
        throw 'Untrusted commentary provenance.'
    }
    $start = [DateTimeOffset]::MinValue
    $end = [DateTimeOffset]::MinValue
    $created = [DateTimeOffset]::MinValue
    $expiry = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Provenance.safeOutputJobStartedAt, [ref]$start) -or
        -not [DateTimeOffset]::TryParse([string]$Provenance.safeOutputJobCompletedAt, [ref]$end) -or
        -not [DateTimeOffset]::TryParse([string]$Provenance.artifactCreatedAt, [ref]$created) -or
        -not [DateTimeOffset]::TryParse([string]$Provenance.artifactExpiresAt, [ref]$expiry) -or
        $created -lt $start -or $created -gt $end -or $expiry -le $created -or
        [string]$Provenance.commentarySha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Provenance.inputSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $CommentaryBytes.Length -eq 0 -or $CommentaryBytes.Length -gt 16384 -or
        (Get-CopilotBytesSha256 $CommentaryBytes) -cne $Provenance.commentarySha256) {
        throw 'Invalid commentary provenance or content hash.'
    }
    $commentary = ConvertFrom-CopilotJsonBytes $CommentaryBytes
    if ($commentary -isnot [System.Collections.IDictionary] -or
        -not $commentary.Contains('inputSha256') -or $commentary.inputSha256 -cne $Provenance.inputSha256) {
        throw 'Commentary input digest differs from its provenance.'
    }
    return $true
}

function Get-CopilotPublishedBytes {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$MaxBytes)
    if ($Name -cnotin @('manifest.json', 'commentary.json', 'commentary-provenance.json')) {
        throw 'Unexpected published file.'
    }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(20)
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(20))
    $response = $null
    $stream = $null
    $buffer = [IO.MemoryStream]::new()
    try {
        $uri = "https://aktsmm.github.io/m365-copilot-insights/$Name"
        $response = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw 'Published commentary lookup failed.' }
        if ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -gt $MaxBytes) {
            throw 'Published commentary file exceeds its size limit.'
        }
        $stream = $response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult()
        $chunk = [byte[]]::new(4096)
        while (($read = $stream.ReadAsync($chunk, 0, $chunk.Length, $cancel.Token).GetAwaiter().GetResult()) -gt 0) {
            if ($buffer.Length + $read -gt $MaxBytes) { throw 'Published commentary file exceeds its size limit.' }
            $buffer.Write($chunk, 0, $read)
        }
        return ,$buffer.ToArray()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $buffer.Dispose()
        $cancel.Dispose()
        $client.Dispose()
    }
}

function Get-CopilotReusableCommentary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$RunAttempt,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SafeOutputJob,
        [System.Collections.IDictionary]$ExpiredArtifact,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [scriptblock]$Fetch = { param($Name, $MaxBytes) Get-CopilotPublishedBytes -Name $Name -MaxBytes $MaxBytes }
    )
    $manifestBytes = & $Fetch 'manifest.json' 262144
    $provenanceBytes = & $Fetch 'commentary-provenance.json' 8192
    $commentaryBytes = & $Fetch 'commentary.json' 16384
    $manifest = ConvertFrom-CopilotJsonBytes $manifestBytes
    if ($manifest.schemaVersion -ne 1 -or $manifest.dataClass -cne 'mixed-explicitly-separated' -or
        $manifest.status -cne 'success' -or $manifest.distributionAllowed -ne $true) {
        throw 'Published manifest is not a distributable Pages build.'
    }
    foreach ($item in @(
        @{ name = 'commentary-provenance.json'; bytes = $provenanceBytes },
        @{ name = 'commentary.json'; bytes = $commentaryBytes }
    )) {
        $matches = @($manifest.files | Where-Object { $_.path -ceq $item.name })
        if ($matches.Count -ne 1 -or $matches[0].sha256 -cne (Get-CopilotBytesSha256 $item.bytes)) {
            throw 'Published commentary manifest hash mismatch.'
        }
    }
    $provenance = ConvertFrom-CopilotJsonBytes $provenanceBytes
    $null = Test-CopilotCommentaryProvenance -CommentaryBytes $commentaryBytes -Provenance $provenance `
        -RunId $RunId -RunAttempt $RunAttempt
    if ([string]$SafeOutputJob.id -cne [string]$provenance.safeOutputJobId -or
        [DateTimeOffset]::Parse([string]$SafeOutputJob.started_at) -ne [DateTimeOffset]::Parse([string]$provenance.safeOutputJobStartedAt) -or
        [DateTimeOffset]::Parse([string]$SafeOutputJob.completed_at) -ne [DateTimeOffset]::Parse([string]$provenance.safeOutputJobCompletedAt)) {
        throw 'Published commentary does not match the current safe-output job.'
    }
    $expiry = [DateTimeOffset]::Parse([string]$provenance.artifactExpiresAt)
    if ($expiry -gt $Now) { throw 'The previously published artifact has not expired.' }
    if ($ExpiredArtifact -and ([string]$ExpiredArtifact.id -cne [string]$provenance.artifactId -or
        [DateTimeOffset]::Parse([string]$ExpiredArtifact.created_at) -ne [DateTimeOffset]::Parse([string]$provenance.artifactCreatedAt) -or
        [DateTimeOffset]::Parse([string]$ExpiredArtifact.expires_at) -ne $expiry)) {
        throw 'Published commentary does not match the expired artifact.'
    }
    return [pscustomobject]@{ commentaryBytes = $commentaryBytes; provenanceBytes = $provenanceBytes }
}

Export-ModuleMember -Function ConvertFrom-CopilotJsonBytes, Get-CopilotBytesSha256,
    Test-CopilotCommentaryProvenance, Get-CopilotReusableCommentary
