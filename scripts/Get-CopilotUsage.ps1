#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$CollectorClientId,
    [Parameter(Mandatory)][guid]$PublisherClientId,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$ProbePeriods
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Copilot.Graph.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Copilot.Data.psm1') -Force
$output=[IO.Path]::GetFullPath($OutputDirectory)
if (-not $env:RUNNER_TEMP) { throw 'Live collection requires RUNNER_TEMP' }
$temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
if (-not $output.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) { throw 'Live data may only be written below RUNNER_TEMP' }
if (Test-Path -LiteralPath $output) { throw 'Use an absent output directory, never overwrite a previous collection' }
[void][IO.Directory]::CreateDirectory($output)
$token=Get-CopilotOidcToken -TenantId $TenantId -ClientId $CollectorClientId -ExpectedRoles @('Reports.Read.All','User.Read.All')
$users=[Collections.Generic.List[object]]::new()
$uri='https://graph.microsoft.com/v1.0/users?$select=id,userPrincipalName,department,assignedPlans,accountEnabled&$top=999'
while ($uri) {
    $result=Invoke-CopilotGraph -Uri $uri -Token $token
    $page=$result.Text|ConvertFrom-Json -AsHashtable
    foreach($user in $page.value){$users.Add($user)}
    $uri=$page['@odata.nextLink']
}
[IO.File]::WriteAllText((Join-Path $output 'users.json'),(@{value=$users.ToArray()}|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
$periods=@(if($ProbePeriods){'D7';'D28';'D30';'ALL'}else{'D7'})
$probes=[Collections.Generic.List[object]]::new()
$primaryRows=@()
foreach($period in $periods){
    $uri="https://graph.microsoft.com/v1.0/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='$period')"
    $result=Invoke-CopilotGraph -Uri $uri -Token $token -AllowError
    $rows=@()
    if($result.Status -eq 200){
        $rows=@($result.Text|ConvertFrom-Csv)
        if($rows.Count -eq 0){throw "Report $period has no rows; not a successful data validation"}
        [IO.File]::WriteAllText((Join-Path $output "usage-$period.csv"),$result.Text,[Text.UTF8Encoding]::new($false))
        if($period -eq 'D7'){$primaryRows=$rows}
    }
    $probe=@{period=$period;status=$result.Status;errorCode=$result.ErrorCode;rows=$rows.Count;columns=@(if($rows.Count){$rows[0].PSObject.Properties.Name})}
    if($result.Status -eq 200 -and $period -in @('D7','D28')){
        $probe['sourceUsage']=Measure-CopilotSourceUsage -Rows $rows
    }
    $probes.Add($probe)
}
$betaResponse=Invoke-CopilotGraph -Uri "https://graph.microsoft.com/beta/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D7')" -Token $token -AllowError
$betaProbe=@{status=$betaResponse.Status;errorCode=$betaResponse.ErrorCode}
if($betaResponse.Status -eq 200){
    $betaData=$betaResponse.Text|ConvertFrom-Json -AsHashtable
    $betaProbe['rows']=@($betaData.value).Count
    $betaProbe['columns']=@(if(@($betaData.value).Count){$betaData.value[0].Keys|Sort-Object})
    [IO.File]::WriteAllText((Join-Path $output 'usage-beta-D7.json'),$betaResponse.Text,[Text.UTF8Encoding]::new($false))
}
$daily=@{status='unverified';reason='No primary report refresh date'}
if($primaryRows.Count){
    $refreshColumn=@($primaryRows[0].PSObject.Properties.Name|Where-Object {($_ -replace '[^a-zA-Z]','').ToLowerInvariant() -eq 'reportrefreshdate'})
    if($refreshColumn.Count -ne 1){throw 'Cannot determine actual report refresh date for daily API'}
    $refreshDates=@($primaryRows|ForEach-Object {$_.PSObject.Properties[$refreshColumn[0]].Value}|Sort-Object -Unique)
    if($refreshDates.Count -ne 1){throw 'Mixed refresh dates; daily query requires a unique source date'}
    $date=[DateTime]::Parse($refreshDates[0],[Globalization.CultureInfo]::InvariantCulture).ToString('yyyy-MM-dd')
    $response=Invoke-CopilotGraph -Uri "https://graph.microsoft.com/beta/copilot/reports/getMicrosoft365CopilotUsageUserDetailByDate(date=$date)" -Token $token -AllowError
    $daily=@{status=$response.Status;errorCode=$response.ErrorCode;date=$date}
    if($response.Status -eq 200){
        $detail=$response.Text|ConvertFrom-Json -AsHashtable
        $daily['rows']=@($detail.value).Count
        $daily['columns']=@(if(@($detail.value).Count){$detail.value[0].Keys|Sort-Object})
        [IO.File]::WriteAllText((Join-Path $output 'daily.json'),$response.Text,[Text.UTF8Encoding]::new($false))
    }
}
$publisher=Get-CopilotOidcToken -TenantId $TenantId -ClientId $PublisherClientId -ExpectedRoles @('Sites.Selected')
$negative=Invoke-CopilotGraph -Uri 'https://graph.microsoft.com/v1.0/sites/root?$select=id' -Token $publisher -AllowError
if($negative.Status -ne 403){throw 'Unassigned publisher must receive 403 from the ungranted root site'}
$summary=@{
    collectedAt=[DateTime]::UtcNow.ToString('o');userCount=$users.Count
    departmentSetCount=@($users|Where-Object department).Count
    departmentCount=@($users|Where-Object department|ForEach-Object {$_.department}|Sort-Object -Unique).Count
    periodProbes=$probes.ToArray();betaProbe=$betaProbe;dailyProbe=$daily;publisherUngrantNegative=@{status=$negative.Status;errorCode=$negative.ErrorCode}
    collectorRoles=@('Reports.Read.All','User.Read.All');publisherRoles=@('Sites.Selected')
    rawDataUploaded=$false;distributionAllowed=$false
}
$upns=@{}
foreach($user in $users){$upns[$user.userPrincipalName.Trim().ToLowerInvariant()]=$user}
$matched=0
$missingDepartment=0
$hashed=0
foreach($row in $primaryRows){
    $upn=$row.'User Principal Name'.Trim().ToLowerInvariant()
    if($upn -match '^[0-9a-f]{32}$'){$hashed++}
    if($upns.ContainsKey($upn)){$matched++;if([string]::IsNullOrWhiteSpace($upns[$upn].department)){$missingDepartment++}}
}
$summary['joinQuality']=@{sourceRows=$primaryRows.Count;matchedUpnRows=$matched;unmatchedUpnRows=$primaryRows.Count-$matched;matchedWithoutDepartmentRows=$missingDepartment;hex32IdentifierRows=$hashed}
if($primaryRows.Count){
    $summary['sourceUsage']=Measure-CopilotSourceUsage -Rows $primaryRows
    $summary['sourceReportSha256']=(Get-FileHash -LiteralPath (Join-Path $output 'usage-D7.csv') -Algorithm SHA256).Hash.ToLowerInvariant()
}
[IO.File]::WriteAllText((Join-Path $output 'collection-summary.json'),($summary|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
'collection-summary='+($summary|ConvertTo-Json -Depth 10 -Compress)
if($primaryRows.Count -eq 0){throw 'Primary D7 report unavailable; no build or publication permitted'}
if($env:GITHUB_STEP_SUMMARY){
    $observed=$summary.sourceUsage
    $prompts=$(if($null -eq $observed.KnownPromptTotal){'不明（既知値なし）'}else{$observed.KnownPromptTotal.ToString([Globalization.CultureInfo]::InvariantCulture)})
    $markdown=@(
        '## Diamond：実テナントの取得元データ'
        ''
        '合成fixtureではありません。Graphの実応答からスクリプトで集計しています。'
        ''
        '| 項目 | 実測 |'
        '|---|---|'
        "| 取得成功時刻（UTC） | $($summary.collectedAt) |"
        "| レポート基準日 | $($observed.ReportRefreshDate) |"
        "| レポート期間 | $($observed.ReportPeriod)日（D7） |"
        "| 取得行数 | $($observed.SourceRows) |"
        "| プロンプト数（判明分の合計） | $prompts |"
        "| 回数が判明している行 / 不明の行 | $($observed.KnownPromptRows) / $($observed.UnknownPromptRows) |"
        "| UPN突合成功 / 部署未設定 | $matched / $missingDepartment |"
        "| 32桁16進識別子の行 | $hashed |"
        ''
        '取得元全体の観測であり、部門別集計・配信の成功ではありません。不明値を0へ置き換えていません。'
        '部門別の配信可否は次の厳密突合・生成工程で別判定し、不成立時は停止します。'
        '実個票はrunnerの一時領域だけで処理し、このサマリーにはUPN・表示名・部署名を出しません。'
    ) -join "`n"
    [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,$markdown+"`n",[Text.UTF8Encoding]::new($false))
}
