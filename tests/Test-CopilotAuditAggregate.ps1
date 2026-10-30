#Requires -Version 7.5
# 監査ログ集計 (-AggregateOnly) の回帰テスト。Graph 応答を差し替え、ユーザー名が出力に出ないこと、件数と人数が正しいことを確認する。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script = Join-Path (Split-Path $PSScriptRoot) 'scripts\Get-CopilotAuditSummary.ps1'
$out = Join-Path ([IO.Path]::GetTempPath()) ("audit-agg-test-{0}.csv" -f [guid]::NewGuid())
function Invoke-RestMethod {
    param([string]$Uri, [string]$Method = 'Get', $Headers, $Body)
    if ($Method -eq 'Post') { return [pscustomobject]@{ id = 'q1'; status = 'notStarted' } }
    if ($Uri -match '/records') {
        $mk = { param($u, $d, $app, $agent) [pscustomobject]@{ userPrincipalName = $u; createdDateTime = "${d}T09:00:00Z"; auditData = [pscustomobject]@{ CopilotEventData = [pscustomobject]@{ AppHost = $app; AgentName = $agent } } } }
        return [pscustomobject]@{ value = @(
                (& $mk 'userA' '2026-10-29' 'Office' ''),
                (& $mk 'userA' '2026-10-29' 'Office' ''),
                (& $mk 'userB' '2026-10-29' 'Office' ''),
                (& $mk 'userB' '2026-10-29' 'Teams' 'Researcher')
            ) }
    }
    return [pscustomobject]@{ id = 'q1'; status = 'succeeded' }
}
try {
    $msg = & $script -AccessToken 'dummy' -OutputPath $out -Days 1 -AggregateOnly
    if ($msg -notmatch 'aggregateOnly=true') { throw "unexpected summary: $msg" }
    $text = Get-Content -LiteralPath $out -Raw
    if ($text -match 'userA|userB|userPrincipalName|"user"') { throw 'aggregate output must not contain user identifiers' }
    $rows = Import-Csv -LiteralPath $out
    $office = $rows | Where-Object { $_.appHost -eq 'Office' -and -not $_.agent }
    if ($office.interactions -ne '3' -or $office.distinctUsers -ne '2') { throw "Office aggregate wrong: $($office | ConvertTo-Json -Compress)" }
    $agent = $rows | Where-Object { $_.agent -eq 'Researcher' }
    if ($agent.interactions -ne '1' -or $agent.distinctUsers -ne '1') { throw 'agent aggregate wrong' }
    'Audit aggregate tests passed.'
}
finally { Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue }

