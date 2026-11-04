#requires -Version 7.5
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory, [string]$RunId)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = 'aktsmm/m365-copilot-insights'
function Read-GitHubJson([string]$Endpoint) {
    $result = & gh api -X GET $Endpoint
    if ($LASTEXITCODE -ne 0) { throw 'Commentary metadata lookup failed' }
    $result | ConvertFrom-Json
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
    $run.head_repository.full_name -cne $repo -or $run.conclusion -cne 'success' -or
    $run.path -cne '.github/workflows/measured-commentary.lock.yml' -or $run.event -cne 'workflow_dispatch') {
    throw 'Untrusted commentary workflow run'
}
$artifacts = Read-GitHubJson "repos/$repo/actions/runs/$RunId/artifacts?per_page=100"
$artifactName = 'safe-outputs-upload-artifacts'
$matches = @($artifacts.artifacts | Where-Object { $_.name -ceq $artifactName -and -not $_.expired })
if ($matches.Count -ne 1 -or $matches[0].size_in_bytes -gt 32768) {
    throw 'Expected one bounded, unexpired commentary artifact'
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Commentary output directory must be fresh' }
& gh run download $RunId -R $repo -n $artifactName -D $OutputDirectory
if ($LASTEXITCODE -ne 0) { throw 'Commentary artifact download failed' }
$files = @(Get-ChildItem -LiteralPath $OutputDirectory -File -Recurse)
if ($files.Count -ne 1 -or $files[0].Name -cne 'commentary.json' -or $files[0].Length -gt 16384) {
    throw 'Unexpected commentary artifact contents'
}
$target = Join-Path $OutputDirectory 'commentary.json'
if ($files[0].FullName -cne [IO.Path]::GetFullPath($target)) { throw 'Commentary must be at the artifact root' }
Set-Content -LiteralPath (Join-Path $OutputDirectory 'run-id.txt') -Value $RunId -Encoding utf8 -NoNewline
Write-Output "Validated commentary artifact provenance: run $RunId"
