#Requires -Version 7.5
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('live','calendar')][string]$Mode)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$status = 'failed'
$work = $null
$process = $null
try {
    if ($env:GITHUB_REPOSITORY -cne 'aktsmm/m365-copilot-insights' -or
        $env:GITHUB_REPOSITORY_ID -notmatch '^[1-9][0-9]*$' -or
        $env:GITHUB_RUN_ID -notmatch '^[1-9][0-9]*$' -or
        $env:GITHUB_RUN_ATTEMPT -notmatch '^[1-9][0-9]*$' -or -not $env:RUNNER_TEMP) {
        throw 'Invalid runner context'
    }
    $root = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Runner storage absent' }
    $candidate = Join-Path $root "copilot-private-$Mode-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
    if (Test-Path -LiteralPath $candidate) { throw 'Private work already exists' }
    $ancestor = Get-Item -LiteralPath $root
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Runner path alias rejected' }
        $ancestor = $ancestor.Parent
    }
    [void][IO.Directory]::CreateDirectory($candidate)
    $work = $candidate
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',
        (Join-Path $PSScriptRoot 'Invoke-CopilotPrivateWorker.ps1'),'-Mode',$Mode)) {
        $start.ArgumentList.Add($arg)
    }
    $start.Environment['RUNNER_TEMP'] = $work
    foreach ($name in @('GITHUB_STEP_SUMMARY','GITHUB_OUTPUT','GITHUB_ENV','GITHUB_PATH','GITHUB_STATE')) {
        $start.Environment[$name] = Join-Path $work "$name.txt"
    }
    # Drain both OS streams, including native stdout/stderr and formatted errors.
    # Nothing from the private process is forwarded to the public runner.
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
    $stderr = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
    $process.WaitForExit()
    [void]$stdout.GetAwaiter().GetResult()
    [void]$stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw 'Private processing failed' }
    $status = 'succeeded'
} catch {
    $status = 'failed'
} finally {
    if ($process) { $process.Dispose() }
    if ($work) {
        try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop }
        catch { $status = 'failed' }
    }
}
[Console]::Out.WriteLine((@{schemaVersion=1;operation=$Mode;status=$status;privateOutputPublished=$false} | ConvertTo-Json -Compress))
if ($status -ne 'succeeded') { exit 1 }
