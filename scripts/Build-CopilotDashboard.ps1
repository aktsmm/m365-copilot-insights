#requires -Version 7.0
<#
.SYNOPSIS
Microsoft Graphの取得済みデータから、日本語の部門別レポートを生成します。
.DESCRIPTION
Tenant output is restricted to this workspace's .local directory or RUNNER_TEMP,
never exports. OutputDirectory must be empty; use a new directory for every run.
Synthetic input must match the bundled, allowlisted fixtures. No network is used.
HTMLは日本語で初期表示し、日本語／Englishボタンで固定UIのみ切り替えます。
JavaScript無効時も日本語で読めます。CSV列名と取得元データは翻訳しません。
総プロンプト数は実機で確認された列名と従来の候補名を別名として照合します。
.EXAMPLE
.\Build-CopilotDashboard.ps1 -UsersPath ..\tests\fixtures\users.json -UsagePath ..\tests\fixtures\usage.csv -OutputDirectory ..\exports\synthetic -DataClass synthetic
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UsersPath,
    [Parameter(Mandatory)][string]$UsagePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][ValidateSet('synthetic', 'tenant')][string]$DataClass,
    [switch]$AllowUnmatched
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Copilot.Data.psm1') -Force
Invoke-CopilotDashboard -UsersPath $UsersPath -UsagePath $UsagePath `
    -OutputDirectory $OutputDirectory -DataClass $DataClass -AllowUnmatched:$AllowUnmatched
