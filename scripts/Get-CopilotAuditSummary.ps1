#Requires -Version 7.5
# Purview 監査ログ (CopilotInteraction) を Graph の監査ログクエリで取得し、日別・ユーザー別・アプリ別・エージェント別の件数に集計する。
# 本文・プロンプト内容は保存しない。委任トークン (AuditLogsQuery.Read.All) またはアプリ権限のトークンを -AccessToken で受け取る。
# 無人実行 (OIDC) では `az account get-access-token --resource https://graph.microsoft.com` の結果を渡す。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateRange(1, 30)][int]$Days = 7,
    [int]$TimeoutMinutes = 15,
    [switch]$AggregateOnly
)
$ErrorActionPreference = 'Stop'
$h = @{ Authorization = 'Bearer ' + $AccessToken; 'Content-Type' = 'application/json' }
$start = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('yyyy-MM-ddTHH:mm:ssZ')
$end = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$body = @{ displayName = 'copilot-interaction-summary'; filterStartDateTime = $start; filterEndDateTime = $end; recordTypeFilters = @('copilotInteraction') } | ConvertTo-Json
$q = Invoke-RestMethod -Method Post 'https://graph.microsoft.com/v1.0/security/auditLog/queries' -Headers $h -Body $body
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
while ($q.status -notin 'succeeded', 'failed', 'cancelled') {
    if ((Get-Date) -gt $deadline) { throw "audit query timeout (status=$($q.status))" }
    Start-Sleep 10
    $q = Invoke-RestMethod "https://graph.microsoft.com/v1.0/security/auditLog/queries/$($q.id)" -Headers $h
}
if ($q.status -ne 'succeeded') { throw "audit query $($q.status)" }
function Get-Prop($Object, [string[]]$Path) { $cur = $Object; foreach ($p in $Path) { if ($null -eq $cur -or $cur.PSObject.Properties.Name -notcontains $p) { return '' }; $cur = $cur.$p }; if ($null -eq $cur) { '' } else { [string]$cur } }
$records = [Collections.Generic.List[object]]::new()
$uri = "https://graph.microsoft.com/v1.0/security/auditLog/queries/$($q.id)/records?`$top=1000"
while ($uri) {
    $page = Invoke-RestMethod $uri -Headers $h
    foreach ($r in $page.value) { $records.Add($r) }
    $uri = if ($page.PSObject.Properties.Name -contains '@odata.nextLink') { $page.'@odata.nextLink' } else { $null }
}
$rows = foreach ($r in $records) {
    $data = $r.auditData
    $created = [datetime]::Parse([string]$r.createdDateTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
    [pscustomobject]@{
        date    = $created.ToString('yyyy-MM-dd')
        user    = (Get-Prop $r @('userPrincipalName'))
        appHost = (Get-Prop $data @('CopilotEventData','AppHost'))
        agent   = (Get-Prop $data @('CopilotEventData','AgentName'))
    }
}
if ($AggregateOnly) {
    # 公開してよい集計: ユーザー名を含めず、日付・アプリ・エージェント別の件数と人数だけにする。
    $summary = $rows | Group-Object date, appHost, agent | ForEach-Object {
        $f = $_.Group[0]
        [pscustomobject]@{ date = $f.date; appHost = $f.appHost; agent = $f.agent; interactions = $_.Count; distinctUsers = @($_.Group | Select-Object -ExpandProperty user -Unique).Count }
    } | Sort-Object date, appHost, agent
    $summary | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8
    "records=$($records.Count) groups=$(@($summary).Count) aggregateOnly=true"
    return
}
$summary = $rows | Group-Object date, user, appHost, agent | ForEach-Object {
    $f = $_.Group[0]
    [pscustomobject]@{ date = $f.date; user = $f.user; appHost = $f.appHost; agent = $f.agent; interactions = $_.Count }
} | Sort-Object date, user
$summary | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8
"records=$($records.Count) groups=$(@($summary).Count)"
