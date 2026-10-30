#Requires -Version 7.5
# 公開リポジトリの Actions から、Purview 監査ログ (CopilotInteraction) をユーザー名なしの集計だけで読み取る。
# 専用アプリ (AuditLogsQuery.Read.All のみ) の OIDC トークンを使う。出力はステップサマリーの集計表だけで、成果物・キャッシュ・ユーザー識別子は出さない。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$AuditClientId,
    [ValidateRange(1, 30)][int]$Days = 7
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Copilot.Graph.psm1') -Force
$token = Get-CopilotOidcToken -TenantId $TenantId -ClientId $AuditClientId -ExpectedRoles @('AuditLogsQuery.Read.All')
$work = Join-Path ([IO.Path]::GetTempPath()) ('audit-' + [guid]::NewGuid().ToString('N') + '.csv')
try {
    $result = & (Join-Path $PSScriptRoot 'Get-CopilotAuditSummary.ps1') -AccessToken $token -OutputPath $work -Days $Days -AggregateOnly
    $rows = @(Import-Csv -LiteralPath $work)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("## Copilot 監査ログ集計 (直近 $Days 日, ユーザー名なし)")
    $lines.Add('')
    $lines.Add($result)
    $lines.Add('')
    $lines.Add('| 日付 | アプリ | エージェント | 件数 | 人数 |')
    $lines.Add('| --- | --- | --- | --- | --- |')
    foreach ($r in $rows) { $lines.Add("| $($r.date) | $($r.appHost) | $(if ($r.agent) { $r.agent } else { '(なし)' }) | $($r.interactions) | $($r.distinctUsers) |") }
    $lines | ForEach-Object { Write-Output $_ }
    if ($env:GITHUB_STEP_SUMMARY) { $lines | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
}
finally { Remove-Item -LiteralPath $work -ErrorAction SilentlyContinue }
