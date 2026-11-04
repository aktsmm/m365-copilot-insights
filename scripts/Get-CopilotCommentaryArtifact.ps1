#requires -Version 7.5
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory, [string]$RunId, [string]$ExpectedRunAttempt)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Copilot.CommentaryProvenance.psm1') -Force
$repo = 'aktsmm/m365-copilot-insights'
$explicitRun = -not [string]::IsNullOrWhiteSpace($RunId)
function Read-GitHubJson([string]$Endpoint) {
    $result = & gh api -X GET $Endpoint
    if ($LASTEXITCODE -ne 0) { throw 'Commentary metadata lookup failed' }
    $result | ConvertFrom-Json -AsHashtable -DateKind String
}
if (-not $RunId) {
    $runs = Read-GitHubJson "repos/$repo/actions/workflows/measured-commentary.lock.yml/runs?branch=main&status=success&per_page=1"
    if (-not @($runs.workflow_runs).Count) {
        Write-Output 'No successful measured commentary run yet; building without AI prose.'
        exit 0
    }
    $RunId = [string]$runs.workflow_runs[0].id
}
if ($RunId -notmatch '^[1-9]\d*$') { throw 'Invalid commentary run ID' }
$run = Read-GitHubJson "repos/$repo/actions/runs/$RunId"
if ($run.name -cne 'Measured aggregate commentary' -or $run.head_branch -cne 'main' -or
    $run.head_repository.full_name -cne $repo -or $run.status -cne 'completed' -or $run.conclusion -cne 'success' -or
    $run.path -cne '.github/workflows/measured-commentary.lock.yml' -or $run.event -cne 'workflow_dispatch' -or
    [int]$run.run_attempt -lt 1) {
    throw 'Untrusted commentary workflow run'
}
if ($explicitRun -and ($ExpectedRunAttempt -notmatch '^[1-9]\d*$' -or
    [string]$run.run_attempt -cne $ExpectedRunAttempt)) {
    throw 'The triggering commentary attempt no longer matches the current run'
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Commentary output directory must be fresh' }
$jobs = Read-GitHubJson "repos/$repo/actions/runs/$RunId/attempts/$($run.run_attempt)/jobs?per_page=100"
$safeJobs = @($jobs.jobs | Where-Object { $_.name -ceq 'safe_outputs' })
if ($jobs.total_count -gt 100 -or $safeJobs.Count -ne 1 -or
    [int]$safeJobs[0].run_attempt -ne [int]$run.run_attempt -or
    $safeJobs[0].status -cne 'completed' -or $safeJobs[0].conclusion -cne 'success') {
    throw 'The current attempt has no successful safe-output job'
}
$safeJob = $safeJobs[0]
$processSteps = @($safeJob.steps | Where-Object { $_.name -ceq 'Process Safe Outputs' })
if ($processSteps.Count -ne 1 -or $processSteps[0].conclusion -cne 'success') {
    throw 'The safe-output handler did not complete successfully'
}
$artifacts = Read-GitHubJson "repos/$repo/actions/runs/$RunId/artifacts?per_page=100"
$artifactName = 'commentary.json'
$artifactMatches = @($artifacts.artifacts | Where-Object { $_.name -ceq $artifactName })
if ($artifacts.total_count -gt 100 -or $artifactMatches.Count -gt 1) { throw 'Ambiguous final commentary artifacts' }
if ($artifactMatches.Count -eq 1 -and $artifactMatches[0].expired -isnot [bool]) {
    throw 'Invalid final commentary artifact expiry state'
}
if ($artifactMatches.Count -eq 1 -and -not $artifactMatches[0].expired) {
    $artifact = $artifactMatches[0]
    if ([string]$artifact.id -notmatch '^[1-9]\d*$' -or $artifact.size_in_bytes -le 0 -or
        $artifact.size_in_bytes -gt 32768 -or -not $artifact.expires_at -or
        [string]$artifact.workflow_run.id -cne $RunId) {
        throw 'Invalid final commentary artifact metadata'
    }
    & gh run download $RunId -R $repo -n $artifactName -D $OutputDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Commentary artifact download failed' }
    $files = @(Get-ChildItem -LiteralPath $OutputDirectory -File -Recurse)
    $target = Join-Path $OutputDirectory 'commentary.json'
    if ($files.Count -ne 1 -or $files[0].Name -cne 'commentary.json' -or
        $files[0].Length -gt 16384 -or $files[0].FullName -cne [IO.Path]::GetFullPath($target) -or
        ($files[0].Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Unexpected final commentary artifact contents'
    }
    $bytes = [IO.File]::ReadAllBytes($target)
    $commentary = ConvertFrom-CopilotJsonBytes $bytes
    $provenance = [ordered]@{
        schemaVersion = 1; source = 'safe-output-artifact'; runId = $RunId; runAttempt = [int]$run.run_attempt
        safeOutputJobId = [string]$safeJob.id; safeOutputJobStartedAt = [string]$safeJob.started_at
        safeOutputJobCompletedAt = [string]$safeJob.completed_at; artifactId = [string]$artifact.id
        artifactName = $artifactName; artifactCreatedAt = [string]$artifact.created_at; artifactExpiresAt = [string]$artifact.expires_at
        commentarySha256 = Get-CopilotBytesSha256 $bytes; inputSha256 = $commentary.inputSha256
    }
    $null = Test-CopilotCommentaryProvenance -CommentaryBytes $bytes -Provenance $provenance `
        -RunId $RunId -RunAttempt ([int]$run.run_attempt)
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'provenance.json'), (($provenance | ConvertTo-Json) + "`n"), $utf8)
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'run-id.txt'), $RunId, $utf8)
    Write-Output "Validated final safe-output artifact: run $RunId"
    return
}
if ($explicitRun) { throw 'The triggering commentary run has no unexpired final safe-output artifact' }
$expired = if ($artifactMatches.Count -eq 1) { $artifactMatches[0] } else { $null }
$reuse = Get-CopilotReusableCommentary -RunId $RunId -RunAttempt ([int]$run.run_attempt) `
    -SafeOutputJob $safeJob -ExpiredArtifact $expired
[void][IO.Directory]::CreateDirectory($OutputDirectory)
[IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'commentary.json'), $reuse.commentaryBytes)
[IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'provenance.json'), $reuse.provenanceBytes)
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'run-id.txt'), $RunId, [Text.UTF8Encoding]::new($false))
Write-Output "Reused previously published safe-output artifact: run $RunId"
