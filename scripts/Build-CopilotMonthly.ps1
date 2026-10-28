#requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SnapshotsPath,
    [Parameter(Mandatory)][string[]]$Months,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$AsOfDate = [datetime]::UtcNow.ToString('yyyy-MM-dd'),
    [string]$GeneratedAt = [datetimeoffset]::UtcNow.ToString('o'),
    [string]$EmptyMetadataPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Copilot.Calendar.psm1') -Force
$snapshots = @(Read-CopilotDailySnapshots -Path $SnapshotsPath)
$parameters = @{ Snapshots=$snapshots; Months=$Months; AsOfDate=$AsOfDate; GeneratedAt=$GeneratedAt }
if ($EmptyMetadataPath) {
    $metadata = @(Read-CopilotDailySnapshots -Path $EmptyMetadataPath)
    if ($metadata.Count -ne 1) { throw 'Expected one EmptyMetadata document.' }
    $parameters.EmptyMetadata = $metadata[0]
}
$payload = Get-CopilotMonthlyPayload @parameters
Export-CopilotMonthly -Payload $payload -OutputDirectory $OutputDirectory
