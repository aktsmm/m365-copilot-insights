#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PocRoot = Split-Path $PSScriptRoot -Parent
$script:WorkspaceRoot = Split-Path (Split-Path $script:PocRoot -Parent) -Parent
$script:PromptCandidates = @('Prompts submitted for All Apps', 'All Apps Copilot Prompts Submitted', 'All Apps Copilot Prompts Submitted Count')
# Canonical UTF-8/LF fixture digests: changing a fixture requires explicit reapproval.
$script:SyntheticHashes = @{
    users = '17ba7421c762f071f96aada716a73c39477fbe5d66941f8366035118e144fe55'
    usage = 'b47eea3a8e79f00403d7beb551c825ce914d7c0aecc0599b6e019a044073054d'
}

function Get-TextHash([string]$Text) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Write-Utf8File([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

function Test-WithinPath([string]$Path, [string]$Root) {
    $base = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $Path.Equals($base, $comparison) -or $Path.StartsWith($base + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Assert-OutputPath([string]$OutputDirectory, [string]$DataClass) {
    if ([string]::IsNullOrWhiteSpace($OutputDirectory) -or $OutputDirectory -match '(^|[\\/])\.\.([\\/]|$)') {
        throw 'Unsafe OutputDirectory: parent traversal is not allowed.'
    }
    $full = [IO.Path]::GetFullPath($OutputDirectory)
    if ($DataClass -eq 'tenant') {
        if ($full -match '(^|[\\/])exports([\\/]|$)') { throw 'Tenant output is forbidden in exports.' }
        $allowed = Test-WithinPath $full (Join-Path $script:WorkspaceRoot '.local')
        if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
            $allowed = $allowed -or (Test-WithinPath $full $env:RUNNER_TEMP)
        }
        if (-not $allowed) { throw 'Tenant output requires workspace .local or RUNNER_TEMP.' }
    }
    $ancestor = $full
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Unsafe OutputDirectory: symlink or reparse-point ancestor.'
            }
        }
        $parent = Split-Path $ancestor -Parent
        if ($parent -eq $ancestor) { break }
        $ancestor = $parent
    }
    if (Test-Path -LiteralPath $full) {
        if (-not (Get-Item -LiteralPath $full).PSIsContainer -or
            @(Get-ChildItem -LiteralPath $full -Force).Count -ne 0) {
            throw 'OutputDirectory must be empty; existing reports are never overwritten.'
        }
    }
    $full
}

function Read-UsageCsv([string]$Text) {
    $reader = [IO.StringReader]::new($Text)
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($reader)
    try {
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false
        if ($parser.EndOfData) { throw 'Empty usage CSV.' }
        $headers = $parser.ReadFields()
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($header in $headers) {
            if ([string]::IsNullOrWhiteSpace($header) -or -not $seen.Add($header)) { throw 'Empty or duplicate CSV header.' }
        }
        foreach ($required in @('User Principal Name', 'Report Refresh Date', 'Report Period')) {
            if ($headers -cnotcontains $required) { throw "Missing required CSV column: $required" }
        }
        $rows = [Collections.Generic.List[object]]::new()
        while (-not $parser.EndOfData) {
            $fields = $parser.ReadFields()
            if ($fields.Count -ne $headers.Count) { throw 'CSV field count differs from header.' }
            $row = [ordered]@{}
            for ($i = 0; $i -lt $headers.Count; $i++) { $row[$headers[$i]] = $fields[$i] }
            $rows.Add($row)
        }
        if ($rows.Count -eq 0) { throw 'Empty usage data is not a successful report.' }
        @{ Headers = $headers; Rows = $rows.ToArray() }
    }
    finally { $parser.Dispose(); $reader.Dispose() }
}

function ConvertTo-SafeCsvText([object]$Value) {
    $text = [string]$Value
    if ($text -match '^[\s\p{C}]*[=+\-@]' -or $text -match '^[\t\r\n]') { $text = "'" + $text }
    '"' + $text.Replace('"', '""') + '"'
}

function ConvertTo-ReportCsv([object[]]$Rows, [string[]]$Columns) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add((($Columns | ForEach-Object { ConvertTo-SafeCsvText $_ }) -join ','))
    foreach ($row in $Rows) {
        $lines.Add((($Columns | ForEach-Object { ConvertTo-SafeCsvText $row[$_] }) -join ','))
    }
    ($lines -join "`n") + "`n"
}

function Get-CopilotPromptCount([Collections.IDictionary]$Source, [string[]]$Columns) {
    $prompts = $null
    foreach ($candidate in $Columns) {
        if ([string]::IsNullOrWhiteSpace($Source[$candidate])) { continue }
        $numberText = ([string]$Source[$candidate]).Trim()
        [long]$number = 0
        if ($numberText -notmatch '^[0-9]+$' -or
            -not [long]::TryParse($numberText, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            throw 'Invalid prompt count: nonnegative Int64 integer required.'
        }
        if ($null -ne $prompts -and $prompts -ne $number) {
            throw 'Conflicting total prompt aliases; counts must agree and are never added.'
        }
        $prompts = $number
    }
    $prompts
}

function Get-CopilotSnapshot([Collections.IDictionary]$Source) {
    $period = ([string]$Source['Report Period']).Trim()
    if ($period -notmatch '^(7|28|30|90|180)$') { throw 'Invalid Report Period; expected 7, 28, 30, 90, or 180.' }
    $refresh = ([string]$Source['Report Refresh Date']).Trim()
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($refresh, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$date)) { throw 'Invalid Report Refresh Date.' }
    @{ ReportPeriod = $period; ReportRefreshDate = $refresh }
}

function Measure-CopilotSourceUsage {
    <#
    .SYNOPSIS
    取得元CSVの全体集計のみを返します。部門照合・配布許可・取得認証の証明ではありません。
    .DESCRIPTION
    個票識別情報を参照・出力せず、入力行数・既知/不明のプロンプト数・期間を検査します。
    known行が0なら合計はnull、明示された0件は既知として扱います。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Rows)
    if ($null -eq $Rows -or $Rows.Count -eq 0) { throw 'Empty usage data is not a successful source observation.' }
    $periods = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $refreshDates = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [decimal]$total = 0
    $known = 0
    $unknown = 0
    foreach ($row in $Rows) {
        if ($null -eq $row) { throw 'Invalid source row.' }
        $source = [ordered]@{}
        foreach ($name in (@('Report Refresh Date', 'Report Period') + $script:PromptCandidates)) {
            if ($row -is [Collections.IDictionary]) {
                if (@($row.Keys) -ccontains $name) { $source[$name] = $row[$name] }
            }
            else {
                $property = @($row.PSObject.Properties | Where-Object Name -CEQ $name)
                if ($property.Count -eq 1) { $source[$name] = $property[0].Value }
            }
        }
        foreach ($required in @('Report Refresh Date', 'Report Period')) {
            if (-not $source.Contains($required)) { throw "Missing required CSV column: $required" }
        }
        $snapshot = Get-CopilotSnapshot $source
        [void]$periods.Add($snapshot.ReportPeriod)
        [void]$refreshDates.Add($snapshot.ReportRefreshDate)
        $columns = @($script:PromptCandidates | Where-Object { $source.Contains($_) })
        $count = Get-CopilotPromptCount $source $columns
        if ($null -eq $count) { $unknown++ }
        else { $known++; $total += [decimal]$count }
    }
    if ($periods.Count -ne 1 -or $refreshDates.Count -ne 1) { throw 'Mixed report periods or refresh snapshots would double count users.' }
    [pscustomobject][ordered]@{
        SourceRows = $Rows.Count
        KnownPromptRows = $known
        UnknownPromptRows = $unknown
        KnownPromptTotal = $(if ($known -gt 0) { $total } else { $null })
        ReportRefreshDate = @($refreshDates)[0]
        ReportPeriod = @($periods)[0]
        ObservationScope = 'source-only'
        DistributionAllowed = $false
    }
}

function Get-RowMetrics([object[]]$Rows) {
    [decimal]$known = 0
    $unknown = 0
    foreach ($row in $Rows) {
        if ($null -eq $row['Prompts Submitted']) { $unknown++ }
        else { $known += [decimal]$row['Prompts Submitted'] }
    }
    [ordered]@{
        reportUsers = $Rows.Count
        knownPromptsSubmitted = $known
        unknownPromptUsers = $unknown
        promptsSubmitted = $(if ($unknown -eq 0) { $known } else { $null })
    }
}

function New-UiText([string]$Japanese, [string]$English) {
    '<span data-ja="' + [Net.WebUtility]::HtmlEncode($Japanese) + '" data-en="' +
        [Net.WebUtility]::HtmlEncode($English) + '">' + [Net.WebUtility]::HtmlEncode($Japanese) + '</span>'
}

function ConvertTo-ReportHtml([string]$Template, [string]$Department,
    [object[]]$Rows, [string[]]$Columns, [string]$DataClass, [bool]$Partial,
    [bool]$Administrator = $false, [int]$QuarantineCount = 0) {
    $labels = @{
        'User Principal Name' = @('ユーザー名（UPN）', 'User principal name (UPN)')
        'Display Name' = @('表示名', 'Display name')
        Department = @('部門', 'Department')
        'Report Refresh Date' = @('レポート更新日', 'Report refresh date')
        'Report Period' = @('集計期間（日数）', 'Report period (days)')
        'Prompts Submitted' = @('送信プロンプト数', 'Prompts submitted')
        'Prompts Status' = @('プロンプト数の取得状況', 'Prompt count availability')
        'Last Activity Date' = @('最終利用日（全体）', 'Last activity date (overall)')
        'Copilot Chat Last Activity Date' = @('Copilot Chat 最終利用日', 'Copilot Chat last activity date')
    }
    foreach ($app in @('Microsoft Teams', 'Word', 'Excel', 'PowerPoint', 'Outlook', 'OneNote', 'Loop')) {
        $labels["$app Copilot Last Activity Date"] = @("$app Copilot 最終利用日", "$app Copilot last activity date")
    }
    $html = [Text.StringBuilder]::new()
    [void]$html.Append('<table><caption>' + (New-UiText 'ユーザー別の利用状況' 'Usage by user') + '</caption><thead><tr>')
    foreach ($column in $Columns) {
        $label = if ($labels.ContainsKey($column)) { New-UiText $labels[$column][0] $labels[$column][1] } else { [Net.WebUtility]::HtmlEncode($column) }
        [void]$html.Append('<th scope="col">' + $label + '</th>')
    }
    [void]$html.Append('</tr></thead><tbody>')
    foreach ($row in $Rows) {
        [void]$html.Append('<tr>')
        foreach ($column in $Columns) {
            $value = if ($null -eq $row[$column] -or
                ($column -cmatch '(^| )Last Activity Date$' -and [string]::IsNullOrWhiteSpace($row[$column]))) {
                New-UiText '不明' 'Unknown'
            }
            elseif ($column -ceq 'Prompts Status') {
                if ($row[$column] -ceq 'known') { New-UiText '取得済み' 'Available' } else { New-UiText '不明' 'Unknown' }
            }
            else { [Net.WebUtility]::HtmlEncode([string]$row[$column]) }
            [void]$html.Append('<td>' + $value + '</td>')
        }
        [void]$html.Append('</tr>')
    }
    [void]$html.Append('</tbody></table>')
    $view = if ($Administrator) { New-UiText '管理者向け・全部門' 'Administrator · all departments' }
        else { New-UiText '部門別レポート' 'Department report' }
    $scope = if ($Administrator) {
        '<p class="notice restricted">' + (New-UiText '管理者専用：全部門の情報を含みます。このページを部門向けに配布しないでください。' `
            'ADMIN ONLY: contains all departments. Never distribute this page to a department.') + '</p>'
    }
    else {
        '<p class="department">' + (New-UiText '対象部門' 'Department') + '：<strong>' +
            [Net.WebUtility]::HtmlEncode($Department) + '</strong></p><p class="notice">' +
            (New-UiText 'このページには対象部門のデータだけを掲載しています。部門別レポートであることは、共有権限の設定を保証するものではありません。' `
                'This page contains only the named department. Department scoping does not establish sharing permissions.') + '</p>'
    }
    $banner = if ($DataClass -eq 'synthetic') {
        '<p class="notice synthetic">' + (New-UiText '検査用サンプル（合成データ）です。実在するユーザーの利用状況でも、実テナントでの検証成功を示す証拠でもありません。' `
            'SYNTHETIC TEST SAMPLE: not real user activity and not evidence of successful tenant validation.') + '</p>'
    }
    else { '<p class="data-class">' + (New-UiText '実テナントデータ：取り扱いと共有範囲にご注意ください。' `
        'Tenant data: protect this report and restrict sharing.') + '</p>' }
    $state = if ($Partial) {
        '<p class="notice restricted">' + (New-UiText '一部のデータを隔離しています。照合未完了のため、配布は禁止です。' `
            'PARTIAL: some records are quarantined. Distribution is blocked until reconciliation is complete.') + '</p>'
    }
    else { '<p class="build-status">' + (New-UiText 'データ照合：完了（配信・共有権限の検証とは異なります）' `
        'Data reconciliation: complete (delivery and access permissions are not verified).') + '</p>' }
    $metrics = Get-RowMetrics $Rows
    $cards = [Text.StringBuilder]::new()
    foreach ($card in @(
        @{ Ja = '掲載ユーザー数'; En = 'Users in this view'; Value = $metrics.reportUsers },
        @{ Ja = '取得済みプロンプト数の合計'; En = 'Sum of known prompt counts'; Value = $metrics.knownPromptsSubmitted },
        @{ Ja = 'プロンプト数が不明のユーザー'; En = 'Users with unknown prompt counts'; Value = $metrics.unknownPromptUsers }
    )) {
        [void]$cards.Append('<div class="metric"><dt>' + (New-UiText $card.Ja $card.En) + '</dt><dd>' +
            [Net.WebUtility]::HtmlEncode(([IFormattable]$card.Value).ToString('0', [Globalization.CultureInfo]::InvariantCulture)) + '</dd></div>')
    }
    $quarantineNotice = if ($Administrator) {
        '<p>' + (New-UiText '隔離ユーザー数' 'Quarantined users') + '：' + $QuarantineCount + '</p>'
    } else { '' }
    $sourceDescription = if ($DataClass -eq 'tenant') {
        New-UiText '出典：呼び出し元が提供したMicrosoft Graphユーザー情報（JSON）とCopilot利用状況レポート（CSV）。この生成処理自体はテナントへの接続・認証・取得を行わず、対象テナントや取得完了は確認しません。' `
            'Source: caller-supplied Microsoft Graph users JSON and Copilot usage report CSV. This renderer does not connect, authenticate, fetch, or verify the source tenant or collection success.'
    } else {
        New-UiText '出典：固定許可リストで検査した単体試験用fixture。実テナントから取得したデータではありません。' `
            'Source: allowlisted unit-test fixtures, not data collected from a real tenant.'
    }
    $refreshDate = if ($Rows.Count) { [Net.WebUtility]::HtmlEncode([string]$Rows[0]['Report Refresh Date']) } else { New-UiText '不明' 'Unknown' }
    $reportPeriod = if ($Rows.Count) { [Net.WebUtility]::HtmlEncode([string]$Rows[0]['Report Period']) } else { New-UiText '不明' 'Unknown' }
    $source = '<div class="source"><p>' + $sourceDescription + '</p><p>' +
        (New-UiText 'データ基準日（レポート更新日）' 'Data reference date (report refresh date)') + '：<strong>' + $refreshDate +
        '</strong> ／ ' + (New-UiText '集計期間（日数）' 'Report period (days)') + '：<strong>' + $reportPeriod +
        '</strong></p><p>' + (New-UiText '基準日は生成日時・取得日時・最終利用日とは異なります。取得入力の照合用ハッシュはmanifest.jsonに記録しています。' `
            'The reference date is not the generation time, collection time, or last activity date. Input hashes for reconciliation are recorded in manifest.json.') + '</p></div>'
    # One pass prevents source data from becoming a second template directive.
    $values = @{
        VIEW = $view
        SCOPE = $scope
        BANNER = $banner
        STATE = $state
        SOURCE = $source
        METRICS = $cards.ToString()
        QUARANTINE = $quarantineNotice
        TABLE = $html.ToString()
    }
    [regex]::Replace($Template, '\{\{(VIEW|SCOPE|BANNER|STATE|SOURCE|METRICS|QUARANTINE|TABLE)\}\}', [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $values[$match.Groups[1].Value]
    })
}

function Invoke-CopilotDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UsersPath,
        [Parameter(Mandatory)][string]$UsagePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][ValidateSet('synthetic', 'tenant')][string]$DataClass,
        [switch]$AllowUnmatched
    )
    $output = Assert-OutputPath $OutputDirectory $DataClass
    foreach ($inputPath in @($UsersPath, $UsagePath)) {
        if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { throw 'Input file does not exist.' }
    }
    $usersText = [IO.File]::ReadAllText([IO.Path]::GetFullPath($UsersPath))
    $usageText = [IO.File]::ReadAllText([IO.Path]::GetFullPath($UsagePath))
    $sourceHashes = [ordered]@{
        users = Get-TextHash ($usersText.TrimStart([char]0xFEFF).Replace("`r`n", "`n"))
        usage = Get-TextHash ($usageText.TrimStart([char]0xFEFF).Replace("`r`n", "`n"))
    }
    if ($DataClass -eq 'synthetic') {
        foreach ($kind in @('users', 'usage')) {
            if ($sourceHashes[$kind] -ne $script:SyntheticHashes[$kind]) {
                throw 'Synthetic input must match the approved fixture allowlist; relabeling tenant data is forbidden.'
            }
        }
    }
    $json = ConvertFrom-Json -InputObject $usersText -AsHashtable -NoEnumerate
    if ($json -is [Collections.IDictionary]) {
        if ($json.Contains('@odata.nextLink') -and $json['@odata.nextLink']) { throw 'Graph users pagination is incomplete.' }
        if (-not $json.Contains('value') -or $json['value'] -isnot [array]) { throw 'Expected a Graph value array or JSON array.' }
        $users = @($json['value'])
    }
    elseif ($json -is [array]) { $users = @($json) }
    else { throw 'Expected a Graph value array or JSON array.' }
    if ($users.Count -eq 0) { throw 'Empty directory data is not a successful report.' }
    $userMap = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $departmentLabels = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($user in ($users | Sort-Object { [string]$_['userPrincipalName'] } -CaseSensitive)) {
        if ($user -isnot [Collections.IDictionary] -or -not $user.Contains('userPrincipalName')) { throw 'Directory userPrincipalName is required.' }
        $upn = ([string]$user['userPrincipalName']).Trim()
        if ([string]::IsNullOrWhiteSpace($upn)) { throw 'Empty directory userPrincipalName.' }
        if ($userMap.ContainsKey($upn)) { throw 'Duplicate directory UPN.' }
        if ($DataClass -eq 'synthetic' -and $upn -notmatch '^[^@\s]+@example\.invalid$') { throw 'Synthetic UPN domain is not example.invalid.' }
        $department = ([string]$user['department']).Trim()
        $key = $department.ToLowerInvariant()
        if ($key -and -not $departmentLabels.ContainsKey($key)) { $departmentLabels.Add($key, $department) }
        $userMap.Add($upn, @{ DepartmentKey = $key; Upn = $upn.ToLowerInvariant() })
    }
    $csv = Read-UsageCsv $usageText
    $promptColumns = @($script:PromptCandidates | Where-Object { $csv.Headers -ccontains $_ })
    $promptColumn = if ($promptColumns.Count) { $promptColumns[0] } else { $null }
    $activityColumns = @($csv.Headers | Where-Object { $_ -cmatch '(^| )Last Activity Date$' } | Sort-Object -CaseSensitive)
    $columns = @('User Principal Name', 'Display Name', 'Department', 'Report Refresh Date', 'Report Period',
        'Prompts Submitted', 'Prompts Status') + $activityColumns
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $periods = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $refreshDates = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $allRows = [Collections.Generic.List[object]]::new()
    $matched = [Collections.Generic.List[object]]::new()
    $quarantine = [Collections.Generic.List[object]]::new()
    $reasons = [ordered]@{ anonymousOrInvalidUpn = 0; unmatchedUpn = 0; departmentMissing = 0 }
    foreach ($source in $csv.Rows) {
        $upn = ([string]$source['User Principal Name']).Trim().ToLowerInvariant()
        if (-not $seen.Add($upn)) { throw 'Duplicate usage UPN (including case/whitespace variants).' }
        if ($DataClass -eq 'synthetic' -and $upn -notmatch '^[^@\s]+@example\.invalid$') { throw 'Synthetic UPN domain is not example.invalid.' }
        $snapshot = Get-CopilotSnapshot $source
        $period = $snapshot.ReportPeriod
        [void]$periods.Add($period)
        $refresh = $snapshot.ReportRefreshDate
        $date = [datetime]::MinValue
        [void]$refreshDates.Add($refresh)
        $prompts = Get-CopilotPromptCount $source $promptColumns
        $reason = $null
        $department = ''
        if ($upn -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $reason = 'anonymousOrInvalidUpn' }
        elseif (-not $userMap.ContainsKey($upn)) { $reason = 'unmatchedUpn' }
        elseif (-not $userMap[$upn].DepartmentKey) { $reason = 'departmentMissing' }
        else { $department = $departmentLabels[$userMap[$upn].DepartmentKey] }
        $row = [ordered]@{
            'User Principal Name' = $upn
            'Display Name' = $(if ($source.Contains('Display Name')) { $source['Display Name'] } else { '' })
            Department = $department
            'Report Refresh Date' = $refresh
            'Report Period' = $period
            'Prompts Submitted' = $prompts
            'Prompts Status' = $(if ($null -eq $prompts) { 'unknown' } else { 'known' })
        }
        foreach ($column in $activityColumns) {
            $activity = ([string]$source[$column]).Trim()
            if ($activity -and -not [datetime]::TryParseExact($activity, 'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
                throw 'Invalid activity date; dates are never interpreted as usage counts.'
            }
            $row[$column] = $activity
        }
        $allRows.Add($row)
        if ($reason) {
            $reasons[$reason]++
            $quarantine.Add([ordered]@{} + $row + @{ 'Quarantine Reason' = $reason })
        }
        else { $matched.Add($row) }
    }
    if ($periods.Count -ne 1 -or $refreshDates.Count -ne 1) { throw 'Mixed report periods or refresh snapshots would double count users.' }
    if ($quarantine.Count -gt 0 -and -not $AllowUnmatched) {
        throw "Distribution blocked: $($quarantine.Count) quarantined rows; use -AllowUnmatched for explicit partial output."
    }
    $orderedRows = @($allRows | Sort-Object { $_['User Principal Name'] } -CaseSensitive)
    $total = Get-RowMetrics $orderedRows
    $matchedMetrics = Get-RowMetrics @($matched.ToArray())
    $quarantineMetrics = Get-RowMetrics @($quarantine.ToArray())
    if ($matched.Count + $quarantine.Count -ne $csv.Rows.Count -or
        $matchedMetrics.knownPromptsSubmitted + $quarantineMetrics.knownPromptsSubmitted -ne $total.knownPromptsSubmitted -or
        $matchedMetrics.unknownPromptUsers + $quarantineMetrics.unknownPromptUsers -ne $total.unknownPromptUsers) {
        throw 'Source reconciliation failed.'
    }
    $templatePath = Join-Path $script:PocRoot 'templates\dashboard.html'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw 'Dashboard template is missing.' }
    $template = [IO.File]::ReadAllText($templatePath)
    $departments = [Collections.Generic.List[object]]::new()
    $departmentRows = @{}
    foreach ($key in @($departmentLabels.Keys | Sort-Object -CaseSensitive)) {
        $label = $departmentLabels[$key]
        $rows = @($orderedRows | Where-Object { $_.Department -ceq $label })
        if ($rows.Count -eq 0) { continue }
        $slug = 'dept-' + (Get-TextHash $key)
        $metric = Get-RowMetrics $rows
        $directoryCount = @($userMap.Values | Where-Object { $_.DepartmentKey -ceq $key }).Count
        if ($rows.Count -gt $directoryCount) { throw 'Department population reconciliation failed.' }
        $departments.Add([ordered]@{ department = $label; slug = $slug; directoryUsers = $directoryCount; metrics = $metric })
        $departmentRows[$slug] = $rows
    }
    $departmentTotal = 0
    [decimal]$departmentPrompts = 0
    foreach ($department in $departments) {
        $departmentTotal += $department.metrics.reportUsers
        $departmentPrompts += $department.metrics.knownPromptsSubmitted
    }
    if ($departmentTotal -ne $matched.Count -or $departmentPrompts -ne $matchedMetrics.knownPromptsSubmitted) {
        throw 'Department totals do not reconcile.'
    }
    $partial = $quarantine.Count -gt 0
    $status = if ($partial) { 'partial' } else { 'success' }
    $summary = [ordered]@{
        schemaVersion = 1; dataClass = $DataClass; status = $status
        directoryUsers = $users.Count; reportRefreshDate = @($refreshDates)[0]; reportPeriod = @($periods)[0]
        totals = $total; matched = $matchedMetrics; quarantined = $quarantineMetrics
        departments = $departments.ToArray()
    }
    $manifest = [ordered]@{
        schemaVersion = 1; dataClass = $DataClass; status = $status
        distributionAllowed = (-not $partial); rootAudience = 'admin-only'
        directoryUsers = $users.Count; sourceRows = $csv.Rows.Count; matchedRows = $matched.Count
        quarantinedRows = $quarantine.Count; quarantineReasons = $reasons
        promptColumn = $promptColumn; promptColumnCandidates = $script:PromptCandidates
        promptColumnsPresent = $promptColumns
        promptAliasPolicy = 'Validate every nonempty alias; require equal counts; use once; all empty means unknown'
        promptSchemaStatus = $(if ($promptColumns -ccontains 'Prompts submitted for All Apps') { 'parent-observed-live-v1-header' } else { 'provisional-v2-candidates-not-live-verified' })
        activityDatesAreUsageCounts = $false
        sourceHashes = $sourceHashes; sourceHashCanonicalization = 'UTF-8 without BOM; CRLF normalized to LF'
        syntheticFixtureAllowlistVerified = ($DataClass -eq 'synthetic')
        reconciliationPassed = $true
        hashScope = 'Every generated file except manifest.json itself; SHA256 of raw bytes'
        files = @()
    }
    [void][IO.Directory]::CreateDirectory($output)
    foreach ($department in $departments) {
        $directory = Join-Path $output $department.slug
        [void][IO.Directory]::CreateDirectory($directory)
        $rows = $departmentRows[$department.slug]
        Write-Utf8File (Join-Path $directory 'usage.csv') (ConvertTo-ReportCsv $rows $columns)
        Write-Utf8File (Join-Path $directory 'index.html') (ConvertTo-ReportHtml -Template $template `
            -Department $department.department -Rows $rows -Columns $columns -DataClass $DataClass -Partial $partial)
    }
    if ($partial) {
        $directory = Join-Path $output 'quarantine'
        [void][IO.Directory]::CreateDirectory($directory)
        $quarantinedRows = @($quarantine | Sort-Object { $_['User Principal Name'] } -CaseSensitive)
        Write-Utf8File (Join-Path $directory 'usage.csv') (ConvertTo-ReportCsv $quarantinedRows ($columns + 'Quarantine Reason'))
    }
    Write-Utf8File (Join-Path $output 'index.html') (ConvertTo-ReportHtml -Template $template `
        -Department '' -Rows $orderedRows -Columns $columns -DataClass $DataClass -Partial $partial `
        -Administrator $true -QuarantineCount $quarantine.Count)
    Write-Utf8File (Join-Path $output 'summary.json') (($summary | ConvertTo-Json -Depth 20) + "`n")
    $files = @(Get-ChildItem -LiteralPath $output -File -Recurse | ForEach-Object {
        [ordered]@{
            path = [IO.Path]::GetRelativePath($output, $_.FullName).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } | Sort-Object { $_.path } -CaseSensitive)
    $manifest.files = $files
    Write-Utf8File (Join-Path $output 'manifest.json') (($manifest | ConvertTo-Json -Depth 20) + "`n")
    [pscustomobject]@{
        Status = $status; DataClass = $DataClass; OutputDirectory = $output
        SourceRows = $csv.Rows.Count; DepartmentCount = $departments.Count; QuarantinedRows = $quarantine.Count
        DistributionAllowed = (-not $partial)
    }
}

Export-ModuleMember -Function Invoke-CopilotDashboard, Measure-CopilotSourceUsage
