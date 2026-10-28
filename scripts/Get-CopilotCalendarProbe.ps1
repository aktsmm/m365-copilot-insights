#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [guid]$SubscriptionId,
    [guid]$CollectorClientId,
    [switch]$UseActions,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Copilot.Graph.psm1') -Force
$root = Split-Path $PSScriptRoot
$output = [IO.Path]::GetFullPath($OutputDirectory)
$allowed = @([IO.Path]::GetFullPath((Join-Path $root '.local')) + [IO.Path]::DirectorySeparatorChar)
if ($env:RUNNER_TEMP) { $allowed += [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar }
if (-not @($allowed | Where-Object { $output.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -or (Test-Path -LiteralPath $output)) {
    throw 'Use an absent output directory below this workspace .local.'
}
$token = $null
if ($UseActions) {
    if ($CollectorClientId -eq [guid]::Empty) { throw 'CollectorClientId is required for Actions.' }
    $token = Get-CopilotOidcToken -TenantId $TenantId -ClientId $CollectorClientId -ExpectedRoles @('Reports.Read.All', 'User.Read.All')
} else {
    if ($SubscriptionId -eq [guid]::Empty) { throw 'SubscriptionId is required for delegated probes.' }
    $token = & az account get-access-token --subscription $SubscriptionId --resource https://graph.microsoft.com --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Existing delegated Graph authentication is unavailable.' }
}
$part = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
$part = $part.PadRight($part.Length + ((4 - $part.Length % 4) % 4), '=')
$claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
if ($claims.tid -ne $TenantId.ToString() -or (-not $UseActions -and 'Reports.Read.All' -notin $claims.scp.Split(' '))) {
    throw 'Token tenant or delegated report scope mismatch; no consent fallback.'
}
[void][IO.Directory]::CreateDirectory($output)
$utf8 = [Text.UTF8Encoding]::new($false)
$directory = Invoke-CopilotGraph -Uri 'https://graph.microsoft.com/v1.0/users?$select=id,userPrincipalName,displayName,department,accountEnabled&$top=999' -Token $token
$users = $directory.Text | ConvertFrom-Json -AsHashtable
if ($users.ContainsKey('@odata.nextLink')) { throw 'Directory pagination needs explicit handling before this bounded probe.' }
[IO.File]::WriteAllText((Join-Path $output 'users.json'), $directory.Text, $utf8)
$index = @{}
foreach ($user in $users.value) { $index[$user.userPrincipalName.ToLowerInvariant()] = $user }
$report = Invoke-CopilotGraph -Uri "https://graph.microsoft.com/v1.0/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D28')" -Token $token
$rows = @($report.Text | ConvertFrom-Csv)
$dates = @($rows | ForEach-Object { $_.'Report Refresh Date' } | Sort-Object -Unique)
if ($rows.Count -eq 0 -or $dates.Count -ne 1) { throw 'Expected a nonempty stable report with one refresh date.' }
$refresh = [DateTime]::ParseExact($dates[0], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
[IO.File]::WriteAllText((Join-Path $output 'usage-D28.csv'), $report.Text, $utf8)
$stableUpns = @{}
foreach ($stable in $rows) {
    $upn = $stable.'User Principal Name'.ToLowerInvariant()
    if ($stableUpns.ContainsKey($upn) -or -not $index.ContainsKey($upn)) { throw 'Stable report roster is duplicated or not directory-joined.' }
    $stableUpns[$upn] = $true
}
$summary = @{
    capturedAt = [DateTime]::UtcNow.ToString('o')
    source = 'graph-beta-usage-by-date'; delegatedProbe = (-not $UseActions)
    runtimeApplicationVerified = [bool]$UseActions
    stableRows = $rows.Count; reportRefreshDate = $refresh.ToString('yyyy-MM-dd')
    allAppsPromptMetricAvailable = $false
    reason = '日別APIの全アプリ指標はactions。stableの送信プロンプト数とは異なるため暦月プロンプトとして代用しない。'
    days = @()
}
foreach ($offset in -7..0) {
    $date = $refresh.AddDays($offset).ToString('yyyy-MM-dd')
    $reply = Invoke-CopilotGraph -Uri "https://graph.microsoft.com/beta/copilot/reports/getMicrosoft365CopilotUsageUserDetailByDate(date=$date)" -Token $token -AllowError
    $probe = @{ date = $date; status = $reply.Status; errorCode = $reply.ErrorCode }
    if ($reply.Status -eq 200) {
        $daily = $reply.Text | ConvertFrom-Json -AsHashtable
        [IO.File]::WriteAllText((Join-Path $output "raw-$date.json"), $reply.Text, $utf8)
        $seen = @{}
        foreach ($row in $daily.value) {
            $upn = $row.userPrincipalName.ToLowerInvariant()
            if ($seen.ContainsKey($upn) -or -not $stableUpns.ContainsKey($upn)) { throw 'Daily duplicate or unexpected roster UPN: distribution blocked.' }
            if ($row.reportSelectedDate -ne $date -or $row.reportRefreshDate -ne $refresh.ToString('yyyy-MM-dd')) { throw 'Daily report date mismatch.' }
            $seen[$upn] = $row
        }
        $mapped = @(
            foreach ($stable in $rows) {
                $upn = $stable.'User Principal Name'.ToLowerInvariant()
                if (-not $index.ContainsKey($upn)) { throw 'Stable report UPN not in approved directory.' }
                $person = $index[$upn]
                $count = $null
                if ($seen.ContainsKey($upn)) {
                    if (-not $seen[$upn].ContainsKey('allAppsCopilotActionCount')) { throw 'Daily actions schema changed.' }
                    $count = $seen[$upn].allAppsCopilotActionCount
                }
                @{
                    userId = $person.id; upn = $upn; displayName = $person.displayName
                    department = $person.department; count = $count
                }
            }
        )
        $snapshot = @{
            schemaVersion = 1; dataClass = 'tenant'; source = 'graph-beta-usage-by-date'
            metricId = 'all-apps-actions'; metricLabelJa = 'Copilotアクション数（プロンプト数とは異なる）'
            metricLabelEn = 'Copilot actions (not prompts)'; dateBasis = 'UTC'
            selectedDate = $date; reportRefreshDate = $refresh.ToString('yyyy-MM-dd')
            collectedAt = [DateTime]::UtcNow.ToString('o'); collectionComplete = ($seen.Count -eq $rows.Count)
            users = $mapped
        }
        $snapshots = Join-Path $output 'snapshots'
        [void][IO.Directory]::CreateDirectory($snapshots)
        [IO.File]::WriteAllText((Join-Path $snapshots "$date.json"), ($snapshot | ConvertTo-Json -Depth 15), $utf8)
        $probe.rows = $seen.Count
        $probe.fields = @(if ($daily.value.Count -gt 0) { $daily.value[0].Keys | Sort-Object })
    }
    $summary.days += @($probe)
}
[IO.File]::WriteAllText((Join-Path $output 'probe-summary.json'), ($summary | ConvertTo-Json -Depth 12), $utf8)
$summary | ConvertTo-Json -Depth 12 -Compress
