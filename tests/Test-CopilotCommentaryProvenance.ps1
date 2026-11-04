#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts\Copilot.CommentaryProvenance.psm1') -Force
$utf8 = [Text.UTF8Encoding]::new($false)
$work = Join-Path ([IO.Path]::GetTempPath()) ('copilot-commentary-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$previousRunnerTemp = [Environment]::GetEnvironmentVariable('RUNNER_TEMP', 'Process')
$env:RUNNER_TEMP = $work
$checks = 0

function Assert-Condition([bool]$Value, [string]$Name) {
    if (-not $Value) { throw "Failed: $Name" }
    $script:checks++
}
function Assert-Rejected([scriptblock]$Action, [string]$Name, [string]$Expected = '') {
    $rejected = $false
    try { & $Action | Out-Null } catch {
        if ($Expected -and $_.Exception.Message -notlike "*$Expected*") { throw }
        $rejected = $true
    }
    Assert-Condition $rejected $Name
}
function Get-JsonBytes($Value) {
    return ,$utf8.GetBytes(($Value | ConvertTo-Json -Depth 30 -Compress))
}
function Copy-Json($Value) {
    return ($Value | ConvertTo-Json -Depth 30 -Compress | ConvertFrom-Json -AsHashtable -DateKind String)
}

$runId = '123'
$attempt = 1
$job = @{
    id = 456; name = 'safe_outputs'; run_attempt = $attempt; status = 'completed'; conclusion = 'success'
    started_at = '2026-11-04T08:00:00Z'; completed_at = '2026-11-04T08:05:00Z'
    steps = @(@{ name = 'Process Safe Outputs'; conclusion = 'success' })
}
$artifact = @{
    id = 789; name = 'commentary.json'; expired = $false; size_in_bytes = 900
    created_at = '2026-11-04T08:04:00Z'; expires_at = '2026-11-11T08:04:00Z'
    workflow_run = @{ id = 123 }
}
$source = @{
    schemaVersion = 1; inputSha256 = ('a' * 64)
    observations = @(@{ seriesId = '2026-10/all-apps-actions'; text = '取得できた日だけの参考値です。' })
}
$commentaryBytes = Get-JsonBytes $source
$provenance = @{
    schemaVersion = 1; source = 'safe-output-artifact'; runId = $runId; runAttempt = $attempt
    safeOutputJobId = '456'; safeOutputJobStartedAt = $job.started_at; safeOutputJobCompletedAt = $job.completed_at
    artifactId = '789'; artifactName = 'commentary.json'; artifactCreatedAt = $artifact.created_at
    artifactExpiresAt = $artifact.expires_at; commentarySha256 = Get-CopilotBytesSha256 $commentaryBytes
    inputSha256 = $source.inputSha256
}
$now = [DateTimeOffset]::Parse('2026-11-12T00:00:00Z')

function Set-PublicFixture([byte[]]$Body, [System.Collections.IDictionary]$Proof) {
    $proofBytes = Get-JsonBytes $Proof
    $manifest = @{
        schemaVersion = 1; dataClass = 'mixed-explicitly-separated'; status = 'success'; distributionAllowed = $true
        files = @(
            @{ path = 'commentary.json'; sha256 = Get-CopilotBytesSha256 $Body },
            @{ path = 'commentary-provenance.json'; sha256 = Get-CopilotBytesSha256 $proofBytes }
        )
    }
    $script:publicFiles = @{
        'manifest.json' = Get-JsonBytes $manifest
        'commentary.json' = $Body
        'commentary-provenance.json' = $proofBytes
    }
}
$fetch = {
    param($Name, $MaxBytes)
    if (-not $script:publicFiles.ContainsKey($Name)) { throw 'Missing published file' }
    $bytes = $script:publicFiles[$Name]
    if ($bytes.Length -gt $MaxBytes) { throw 'Published file too large' }
    return ,$bytes
}

try {
    Assert-Condition (Test-CopilotCommentaryProvenance -CommentaryBytes $commentaryBytes -Provenance $provenance `
        -RunId $runId -RunAttempt $attempt) 'final provenance'
    foreach ($change in @(
        @{ key = 'source'; value = 'safe-outputs-upload-artifacts' },
        @{ key = 'artifactName'; value = 'safe-outputs-upload-artifacts' },
        @{ key = 'runId'; value = '124' },
        @{ key = 'runAttempt'; value = 2 },
        @{ key = 'safeOutputJobId'; value = '0' },
        @{ key = 'artifactId'; value = '0' },
        @{ key = 'artifactCreatedAt'; value = '2026-11-04T07:59:59Z' },
        @{ key = 'artifactExpiresAt'; value = '2026-11-04T08:03:00Z' },
        @{ key = 'commentarySha256'; value = ('b' * 64) },
        @{ key = 'inputSha256'; value = ('b' * 64) }
    )) {
        $bad = Copy-Json $provenance
        $bad[$change.key] = $change.value
        Assert-Rejected { Test-CopilotCommentaryProvenance -CommentaryBytes $commentaryBytes -Provenance $bad `
            -RunId $runId -RunAttempt $attempt } "invalid $($change.key)"
    }
    $bad = Copy-Json $provenance
    $bad.extra = 'unexpected'
    Assert-Rejected { Test-CopilotCommentaryProvenance -CommentaryBytes $commentaryBytes -Provenance $bad `
        -RunId $runId -RunAttempt $attempt } 'extra provenance field'
    Assert-Rejected { Test-CopilotCommentaryProvenance -CommentaryBytes ([byte[]]::new(16385)) `
        -Provenance $provenance -RunId $runId -RunAttempt $attempt } 'oversize commentary'

    Set-PublicFixture $commentaryBytes $provenance
    $expiredArtifact = Copy-Json $artifact
    $expiredArtifact.expired = $true
    $reuse = Get-CopilotReusableCommentary -RunId $runId -RunAttempt $attempt -SafeOutputJob $job `
        -ExpiredArtifact $expiredArtifact -Now $now -Fetch $fetch
    Assert-Condition ((Get-CopilotBytesSha256 $reuse.commentaryBytes) -ceq $provenance.commentarySha256) 'expired reuse'
    $reuse = Get-CopilotReusableCommentary -RunId $runId -RunAttempt $attempt -SafeOutputJob $job -Now $now -Fetch $fetch
    Assert-Condition ($reuse.provenanceBytes.Length -gt 0) 'expired artifact absent from API'
    Assert-Rejected { Get-CopilotReusableCommentary -RunId $runId -RunAttempt $attempt -SafeOutputJob $job `
        -Now ([DateTimeOffset]::Parse('2026-11-10T00:00:00Z')) -Fetch $fetch } 'unexpired missing artifact'
    Assert-Rejected { Get-CopilotReusableCommentary -RunId '124' -RunAttempt $attempt -SafeOutputJob $job `
        -Now $now -Fetch $fetch } 'new run cannot reuse old commentary'
    Assert-Rejected { Get-CopilotReusableCommentary -RunId $runId -RunAttempt 2 -SafeOutputJob $job `
        -Now $now -Fetch $fetch } 'new attempt cannot reuse old commentary'
    $otherJob = Copy-Json $job
    $otherJob.id = 457
    Assert-Rejected { Get-CopilotReusableCommentary -RunId $runId -RunAttempt $attempt -SafeOutputJob $otherJob `
        -Now $now -Fetch $fetch } 'different safe-output job'
    $otherArtifact = Copy-Json $expiredArtifact
    $otherArtifact.id = 790
    Assert-Rejected { Get-CopilotReusableCommentary -RunId $runId -RunAttempt $attempt -SafeOutputJob $job `
        -ExpiredArtifact $otherArtifact -Now $now -Fetch $fetch } 'different expired artifact'
    $script:publicFiles['commentary.json'] = $utf8.GetBytes('{}')
    Assert-Rejected { Get-CopilotReusableCommentary -RunId $runId -RunAttempt $attempt -SafeOutputJob $job `
        -Now $now -Fetch $fetch } 'tampered published commentary'
    Set-PublicFixture $commentaryBytes $provenance
    $script:publicFiles['commentary-provenance.json'] = $utf8.GetBytes('{}')
    Assert-Rejected { Get-CopilotReusableCommentary -RunId $runId -RunAttempt $attempt -SafeOutputJob $job `
        -Now $now -Fetch $fetch } 'tampered provenance'
    Set-PublicFixture $commentaryBytes $provenance
    $manifest = ConvertFrom-CopilotJsonBytes $script:publicFiles['manifest.json']
    $manifest.files += @($manifest.files[0])
    $script:publicFiles['manifest.json'] = Get-JsonBytes $manifest
    Assert-Rejected { Get-CopilotReusableCommentary -RunId $runId -RunAttempt $attempt -SafeOutputJob $job `
        -Now $now -Fetch $fetch } 'duplicate manifest entry'
    Set-PublicFixture $commentaryBytes $provenance
    $manifest = ConvertFrom-CopilotJsonBytes $script:publicFiles['manifest.json']
    $manifest.distributionAllowed = $false
    $script:publicFiles['manifest.json'] = Get-JsonBytes $manifest
    Assert-Rejected { Get-CopilotReusableCommentary -RunId $runId -RunAttempt $attempt -SafeOutputJob $job `
        -Now $now -Fetch $fetch } 'non-distributable manifest'
    Set-PublicFixture $commentaryBytes $provenance
    $script:publicFiles.Remove('commentary-provenance.json')
    Assert-Rejected { Get-CopilotReusableCommentary -RunId $runId -RunAttempt $attempt -SafeOutputJob $job `
        -Now $now -Fetch $fetch } 'missing provenance'

    $global:CopilotCommentaryTest = @{
        run = @{
            name = 'Measured aggregate commentary'; head_branch = 'main'; head_repository = @{ full_name = 'aktsmm/m365-copilot-insights' }
            status = 'completed'; conclusion = 'success'; path = '.github/workflows/measured-commentary.lock.yml'
            event = 'workflow_dispatch'; run_attempt = 1
        }
        jobs = @{ total_count = 1; jobs = @($job) }
        artifacts = @{ total_count = 1; artifacts = @($artifact) }
        downloadBytes = $commentaryBytes
    }
    function gh {
        $global:LASTEXITCODE = 0
        if ($args[0] -ceq 'api') {
            $endpoint = [string]$args[-1]
            if ($endpoint -like '*/attempts/*/jobs?per_page=100') { return ($global:CopilotCommentaryTest.jobs | ConvertTo-Json -Depth 30 -Compress) }
            if ($endpoint -like '*/artifacts?per_page=100') { return ($global:CopilotCommentaryTest.artifacts | ConvertTo-Json -Depth 30 -Compress) }
            if ($endpoint -like '*/workflows/*/runs?*') { return '{"workflow_runs":[{"id":123}]}' }
            return ($global:CopilotCommentaryTest.run | ConvertTo-Json -Depth 30 -Compress)
        }
        if ($args[0] -ceq 'run' -and $args[1] -ceq 'download') {
            $destination = [string]$args[[array]::IndexOf($args, '-D') + 1]
            [void][IO.Directory]::CreateDirectory($destination)
            [IO.File]::WriteAllBytes((Join-Path $destination 'commentary.json'), $global:CopilotCommentaryTest.downloadBytes)
            return
        }
        throw 'Unexpected mocked gh call'
    }
    $reader = Join-Path $root 'scripts\Get-CopilotCommentaryArtifact.ps1'
    $download = Join-Path $work 'download'
    & $reader -OutputDirectory $download -RunId $runId -ExpectedRunAttempt '1' | Out-Null
    $downloadProof = ConvertFrom-CopilotJsonBytes ([IO.File]::ReadAllBytes((Join-Path $download 'provenance.json')))
    Assert-Condition ($downloadProof.artifactName -ceq 'commentary.json' -and $downloadProof.runAttempt -eq 1) 'final artifact download'
    & $reader -OutputDirectory (Join-Path $work 'manual') -RunId $null -ExpectedRunAttempt $null | Out-Null
    Assert-Condition (Test-Path -LiteralPath (Join-Path $work 'manual\provenance.json')) 'manual dispatch selects latest final artifact'
    $global:CopilotCommentaryTest.artifacts.artifacts = @(@{ name = 'safe-outputs-upload-artifacts'; expired = $false })
    Assert-Rejected { & $reader -OutputDirectory (Join-Path $work 'staging') -RunId $runId -ExpectedRunAttempt '1' } `
        'staging-only run rejected' 'no unexpired final safe-output artifact'
    $global:CopilotCommentaryTest.artifacts.artifacts = @($artifact, $artifact)
    $global:CopilotCommentaryTest.artifacts.total_count = 2
    Assert-Rejected { & $reader -OutputDirectory (Join-Path $work 'duplicate') -RunId $runId -ExpectedRunAttempt '1' } `
        'duplicate final artifacts rejected' 'Ambiguous final commentary artifacts'
    $oldArtifact = Copy-Json $artifact
    $oldArtifact.created_at = '2026-11-04T07:00:00Z'
    $global:CopilotCommentaryTest.artifacts.artifacts = @($oldArtifact)
    $global:CopilotCommentaryTest.artifacts.total_count = 1
    Assert-Rejected { & $reader -OutputDirectory (Join-Path $work 'old-attempt') -RunId $runId -ExpectedRunAttempt '1' } `
        'prior attempt artifact rejected' 'Invalid commentary provenance or content hash'
    $oversizeArtifact = Copy-Json $artifact
    $oversizeArtifact.size_in_bytes = 32769
    $global:CopilotCommentaryTest.artifacts.artifacts = @($oversizeArtifact)
    Assert-Rejected { & $reader -OutputDirectory (Join-Path $work 'oversize') -RunId $runId -ExpectedRunAttempt '1' } `
        'oversize archive rejected' 'Invalid final commentary artifact metadata'
    Assert-Rejected { & $reader -OutputDirectory (Join-Path $work 'wrong-attempt') -RunId $runId -ExpectedRunAttempt '2' } `
        'workflow event attempt mismatch rejected' 'triggering commentary attempt'
    Remove-Item Function:\gh

    $aggregatePath = Join-Path $work 'aggregate.json'
    & node (Join-Path $root 'scripts\Copilot.Commentary.cjs') aggregate `
        (Join-Path $root 'tests\fixtures\public-measured-monthly.json') $aggregatePath
    if ($LASTEXITCODE -ne 0) { throw 'Could not build test aggregate' }
    $aggregate = ConvertFrom-CopilotJsonBytes ([IO.File]::ReadAllBytes($aggregatePath))
    $realCommentary = @{
        schemaVersion = 1; inputSha256 = $aggregate.inputSha256
        observations = @($aggregate.series | ForEach-Object { @{ seriesId = $_.id; text = '欠測があるため参考値として扱います。' } })
    }
    $realBytes = Get-JsonBytes $realCommentary
    $realProof = Copy-Json $provenance
    $realProof.inputSha256 = $aggregate.inputSha256
    $realProof.commentarySha256 = Get-CopilotBytesSha256 $realBytes
    $inputPath = Join-Path $work 'input.json'
    $proofPath = Join-Path $work 'proof.json'
    [IO.File]::WriteAllBytes($inputPath, $realBytes)
    [IO.File]::WriteAllBytes($proofPath, (Get-JsonBytes $realProof))
    $builder = Join-Path $root 'scripts\Build-CopilotPublicPages.ps1'
    $site = Join-Path $work 'site'
    & $builder -OutputDirectory $site -CommentaryPath $inputPath -CommentaryRunId $runId `
        -CommentaryProvenancePath $proofPath | Out-Null
    Assert-Condition ((Get-CopilotBytesSha256 ([IO.File]::ReadAllBytes((Join-Path $site 'commentary.json')))) -ceq `
        $realProof.commentarySha256) 'published commentary preserves final artifact bytes'
    $script:publicFiles = @{
        'manifest.json' = [IO.File]::ReadAllBytes((Join-Path $site 'manifest.json'))
        'commentary.json' = [IO.File]::ReadAllBytes((Join-Path $site 'commentary.json'))
        'commentary-provenance.json' = [IO.File]::ReadAllBytes((Join-Path $site 'commentary-provenance.json'))
    }
    $reuse = Get-CopilotReusableCommentary -RunId $runId -RunAttempt $attempt -SafeOutputJob $job `
        -ExpiredArtifact $expiredArtifact -Now $now -Fetch $fetch
    Assert-Condition ($reuse.commentaryBytes.Length -eq $realBytes.Length) 'real builder manifest supports reuse'
    Assert-Rejected { & $builder -OutputDirectory (Join-Path $work 'missing-proof') -CommentaryPath $inputPath `
        -CommentaryRunId $runId } 'builder requires provenance' 'Commentary provenance is required'
    $stale = Copy-Json $realCommentary
    $stale.inputSha256 = 'a' * 64
    $staleBytes = Get-JsonBytes $stale
    $staleProof = Copy-Json $realProof
    $staleProof.inputSha256 = $stale.inputSha256
    $staleProof.commentarySha256 = Get-CopilotBytesSha256 $staleBytes
    [IO.File]::WriteAllBytes($inputPath, $staleBytes)
    [IO.File]::WriteAllBytes($proofPath, (Get-JsonBytes $staleProof))
    Assert-Rejected { & $builder -OutputDirectory (Join-Path $work 'stale-digest') -CommentaryPath $inputPath `
        -CommentaryRunId $runId -CommentaryProvenancePath $proofPath 2>&1 } `
        'changed aggregate rejects otherwise valid provenance' 'AI commentary contract failed'
    Write-Output "Commentary provenance checks passed: $checks"
    $global:LASTEXITCODE = 0
} finally {
    if (Get-Command gh -CommandType Function -ErrorAction SilentlyContinue) { Remove-Item Function:\gh }
    Remove-Variable -Name CopilotCommentaryTest -Scope Global -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $previousRunnerTemp, 'Process')
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
