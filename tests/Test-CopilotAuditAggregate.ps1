#Requires -Version 7.5
# 監査ログ集計 (-AggregateOnly) の回帰テスト。Graph 応答を差し替え、ユーザー名が出力に出ないこと、件数と人数が正しいことを確認する。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script = Join-Path (Split-Path $PSScriptRoot) 'scripts\Get-CopilotAuditSummary.ps1'
$wrapper = Join-Path (Split-Path $PSScriptRoot) 'scripts\Invoke-CopilotAuditAggregate.ps1'
$out = Join-Path ([IO.Path]::GetTempPath()) ("audit-agg-test-{0}.csv" -f [guid]::NewGuid())
$summary = Join-Path ([IO.Path]::GetTempPath()) ("audit-summary-test-{0}.md" -f [guid]::NewGuid())
$previousSummary = [Environment]::GetEnvironmentVariable('GITHUB_STEP_SUMMARY')
$previousInjection = [Environment]::GetEnvironmentVariable('AUDIT_TEST_INJECT_UNAPPROVED')
$env:AUDIT_TEST_INJECT_UNAPPROVED = '0'
function Start-Sleep { param([int]$Seconds) }
function Import-Module { param($Name, [switch]$Force) }
function Get-CopilotOidcToken { param($TenantId, $ClientId, $ExpectedRoles) return 'dummy' }
function Import-Csv {
    param([string]$LiteralPath)
    $result = @(Microsoft.PowerShell.Utility\Import-Csv -LiteralPath $LiteralPath)
    if ($env:AUDIT_TEST_INJECT_UNAPPROVED -eq '1' -and $result.Count) { $result[0].agent = 'unapproved-injected-name' }
    return $result
}
function Invoke-RestMethod {
    param([string]$Uri, [string]$Method = 'Get', $Headers, $Body)
    if ($Method -eq 'Post') { return [pscustomobject]@{ id = 'q1'; status = 'notStarted' } }
    if ($Uri -match '/records') {
        $mk = { param($u, $d, $app, $agent) [pscustomobject]@{ userPrincipalName = $u; createdDateTime = "${d}T09:00:00Z"; auditData = [pscustomobject]@{ CopilotEventData = [pscustomobject]@{ AppHost = $app; AgentName = $agent } } } }
        return [pscustomobject]@{ value = @(
                (& $mk 'userA' '2026-10-29' 'Office' ''),
                (& $mk 'userA' '2026-10-29' 'Office' ''),
                (& $mk 'userB' '2026-10-29' 'Office' ''),
                (& $mk 'userB' '2026-10-29' 'Teams' 'researcher'),
                [pscustomobject]@{ userPrincipalName = 'userA'; createdDateTime = '2026-10-29T10:00:00Z'; auditData = [pscustomobject]@{ AgentName = 'Analyst'; CopilotEventData = [pscustomobject]@{ AppHost = 'Teams' } } },
                [pscustomobject]@{ userPrincipalName = 'userB'; createdDateTime = '2026-10-29T10:00:00Z'; auditData = [pscustomobject]@{ AgentName = 'Container'; CopilotEventData = [pscustomobject]@{ AppHost = 'Teams'; TargetAgentName = 'Planner Agent' } } },
                (& $mk 'userA' '2026-10-29' 'Teams' 'Sensitive Project'),
                [pscustomobject]@{ userPrincipalName = 'userA'; createdDateTime = '2026-10-29T10:00:00Z'; auditData = [pscustomobject]@{ AgentName = 'Analyst'; CopilotEventData = [pscustomobject]@{ AppHost = 'Teams'; TargetAgentName = 'Custom Agent Z' } } },
                (& $mk 'userB' '2026-10-29' 'Teams' 'Researcher|private'),
                [pscustomobject]@{ userPrincipalName = 'userB'; createdDateTime = '2026-10-29T10:00:00Z'; auditData = [pscustomobject]@{ Operation = 'x' } }
            ) }
    }
    return [pscustomobject]@{ id = 'q1'; status = 'succeeded' }
}
try {
    $msg = & $script -AccessToken 'dummy' -OutputPath $out -Days 1 -AggregateOnly
    if ($msg -notmatch 'aggregateOnly=true') { throw "unexpected summary: $msg" }
    $text = Get-Content -LiteralPath $out -Raw
    if ($text -match 'userA|userB|userPrincipalName|"user"|Sensitive Project|Custom Agent Z|Researcher\|private|Container') { throw 'aggregate output must not contain user identifiers or unapproved agent names' }
    $rows = Import-Csv -LiteralPath $out
    $office = $rows | Where-Object { $_.appHost -eq 'Office' -and -not $_.agent }
    $none = $rows | Where-Object { -not $_.appHost -and -not $_.agent }
    if (-not $none -or $none.interactions -ne '1') { throw 'record without CopilotEventData must still be counted' }
    if ($office.interactions -ne '3' -or $office.distinctUsers -ne '2') { throw "Office aggregate wrong: $($office | ConvertTo-Json -Compress)" }
    $agent = $rows | Where-Object { $_.agent -ceq 'Researcher' }
    if (-not $agent -or $agent.interactions -ne '1' -or $agent.distinctUsers -ne '1') { throw 'nested agent aggregate or canonical label wrong' }
    $rootAgent = $rows | Where-Object { $_.agent -ceq 'Analyst' }
    if (-not $rootAgent -or $rootAgent.interactions -ne '1') { throw 'root AgentName aggregate wrong' }
    $targetAgent = $rows | Where-Object { $_.agent -ceq 'Planner Agent' }
    if (-not $targetAgent -or $targetAgent.interactions -ne '1') { throw 'TargetAgentName must take precedence' }
    $other = @($rows | Where-Object { $_.appHost -eq 'Teams' -and $_.agent -ceq 'その他' })
    if ($other.Count -ne 1 -or $other[0].interactions -ne '3' -or $other[0].distinctUsers -ne '2') { throw 'unapproved names must be grouped before distinct-user counting' }
    if (($rows | Measure-Object -Property interactions -Sum).Sum -ne 10) { throw 'aggregate lost or duplicated records' }

    $null = & $script -AccessToken 'dummy' -OutputPath $out -Days 1
    $privateRows = Import-Csv -LiteralPath $out
    if (-not @($privateRows | Where-Object { $_.agent -eq 'Custom Agent Z' -and $_.user -eq 'userA' }).Count) { throw 'private diagnostic must retain the selected source name' }

    [Environment]::SetEnvironmentVariable('GITHUB_STEP_SUMMARY', $summary)
    $rendered = (& $wrapper -TenantId ([guid]::NewGuid()) -AuditClientId ([guid]::NewGuid()) -Days 1) -join "`n"
    $savedSummary = Get-Content -LiteralPath $summary -Raw -Encoding utf8
    foreach ($value in @($rendered, $savedSummary)) {
        if ($value -match 'userA|userB|Sensitive Project|Custom Agent Z|Researcher\|private|Container') { throw 'public audit output leaked a user or unapproved name' }
        foreach ($label in @('Researcher', 'Analyst', 'Planner Agent', 'その他')) {
            if (-not $value.Contains($label)) { throw "public audit output omitted approved label: $label" }
        }
    }

    $env:AUDIT_TEST_INJECT_UNAPPROVED = '1'
    $rejected = $false
    try { $null = & $wrapper -TenantId ([guid]::NewGuid()) -AuditClientId ([guid]::NewGuid()) -Days 1 }
    catch {
        if ($_.Exception.Message -notmatch 'unapproved public agent label' -or $_.Exception.Message -match 'unapproved-injected-name') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'public wrapper must reject an unapproved output label' }
    if ((Get-Content -LiteralPath $summary -Raw -Encoding utf8) -cne $savedSummary) { throw 'rejected label must not update the public summary' }
    'Audit aggregate tests passed.'
}
finally {
    [Environment]::SetEnvironmentVariable('GITHUB_STEP_SUMMARY', $previousSummary)
    [Environment]::SetEnvironmentVariable('AUDIT_TEST_INJECT_UNAPPROVED', $previousInjection)
    Remove-Item -LiteralPath $out, $summary -ErrorAction SilentlyContinue
}
