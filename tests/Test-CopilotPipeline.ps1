#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pocRoot = Split-Path $PSScriptRoot -Parent
$build = Join-Path $pocRoot 'scripts/Build-CopilotDashboard.ps1'
$fixtureUsers = Join-Path $PSScriptRoot 'fixtures\users.json'
$fixtureUsage = Join-Path $PSScriptRoot 'fixtures\usage.csv'
$work = Join-Path $PSScriptRoot ('.test-work-' + [guid]::NewGuid().ToString('N'))
$oldRunnerTemp = $env:RUNNER_TEMP
$script:Assertions = 0
$script:CaseNumber = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:Assertions++
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Assert-Throws([scriptblock]$Action, [string]$Expected) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught) "Expected error: $Expected"
    Assert-True ($caught.Exception.Message -match $Expected) "Error mismatch: $($caught.Exception.Message); expected $Expected"
}

function Write-TestInput([object[]]$Users, [object[]]$Usage) {
    $script:CaseNumber++
    $inputRoot = Join-Path $work "case-$script:CaseNumber"
    [void][IO.Directory]::CreateDirectory($inputRoot)
    [IO.File]::WriteAllText((Join-Path $inputRoot 'users.json'), (ConvertTo-Json -InputObject @($Users) -Depth 10), [Text.UTF8Encoding]::new($false))
    $lines = @($Usage | ConvertTo-Csv -NoTypeInformation)
    [IO.File]::WriteAllText((Join-Path $inputRoot 'usage.csv'), ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    @{ UsersPath = Join-Path $inputRoot 'users.json'; UsagePath = Join-Path $inputRoot 'usage.csv'; OutputDirectory = Join-Path $inputRoot 'output'; DataClass = 'tenant' }
}

function Get-FixtureUsers { @((Get-Content -LiteralPath $fixtureUsers -Raw -Encoding UTF8 | ConvertFrom-Json).value) }
function Get-FixtureUsage { @(Import-Csv -LiteralPath $fixtureUsage -Encoding UTF8) }
function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }

function Assert-JapaneseUi([string]$Html) {
    Assert-True ($Html.Contains('<html lang="ja">')) 'Initial document language is Japanese'
    $staticHtml = [regex]::Replace($Html, '<script>[\s\S]*?</script>', '')
    Assert-True ($staticHtml.Contains('Microsoft 365 Copilot 利用状況') -and $staticHtml.Contains('ユーザー別の詳細')) 'Japanese report visible without JavaScript'
    Assert-True ($staticHtml.Contains('検査用サンプル（合成データ）です。') -and
        $staticHtml.Contains('実テナントでの検証成功を示す証拠でもありません。') -and
        $staticHtml.Contains('不明は0件ではありません。')) 'Prominent unit-test-only synthetic banner and unknown semantics'
    Assert-True ($staticHtml.Contains('aria-pressed="true" aria-label="日本語で表示"') -and
        $staticHtml.Contains('aria-pressed="false" aria-label="英語で表示"')) 'Accessible language buttons initialize in Japanese'
    Assert-True ($staticHtml.Contains('role="region" tabindex="0"') -and $staticHtml.Contains('aria-describedby="table-hint"')) 'Keyboard-accessible table scroll region'
    Assert-True ($Html.Contains('overflow-x: auto') -and $Html.Contains('min-width: 0') -and
        $Html.Contains('@media (max-width: 600px)') -and $Html.Contains(':focus-visible')) 'Responsive layout and visible focus rules'
    Assert-True ($Html.Contains('document.documentElement.lang = language') -and
        $Html.Contains('element.textContent = element.getAttribute("data-" + language)') -and
        $Html.Contains('element.setAttribute("aria-label"') -and $Html.Contains('button.setAttribute("aria-pressed"')) 'Language switch updates language, text, accessible names, and pressed state'
    Assert-True ($Html -notmatch '\.innerHTML\s*=|on(click|error|load)=["'']') 'Language switch does not inject HTML or inline event data'
    $fixedLabels = [regex]::Matches($staticHtml, '<(?:span|title|h1|h2|p|li|a)\b[^>]*data-ja="([^"]*)" data-en="([^"]*)"[^>]*>([^<]*)</(?:span|title|h1|h2|p|li|a)>')
    Assert-True ($fixedLabels.Count -gt 20) 'Japanese and English dictionaries cover fixed UI'
    foreach ($label in $fixedLabels) {
        Assert-True ($label.Groups[1].Value -ceq $label.Groups[3].Value) 'Japanese dictionary matches no-JavaScript initial text'
        Assert-True (-not [string]::IsNullOrWhiteSpace($label.Groups[2].Value)) 'English translation is nonempty'
    }
    Assert-True ($staticHtml -notmatch '<td[^>]*>unknown</td>|<th[^>]*>Report Period</th>|<td[^>]*>known</td>') 'Status and column names are localized before JavaScript'
    Assert-True ($staticHtml.Contains('SharePointへの保存とブラウザー内での対話表示は別の機能')) 'Delivery and interactive hosting remain distinct'
    Assert-True ($staticHtml -notmatch 'provisional until|live v2 export') 'Obsolete schema warning removed'
    Assert-True ($staticHtml.Contains('単体試験用fixture') -and $staticHtml.Contains('データ基準日（レポート更新日）')) 'Sample provenance and reference date are Japanese'
    Assert-True ($staticHtml.Contains('<strong>2026-10-27</strong>') -and $staticHtml.Contains('<strong>30</strong>')) 'Reference date and period come from source rows'
}

try {
    [void][IO.Directory]::CreateDirectory($work)
    $env:RUNNER_TEMP = $work
    foreach ($path in @($build, (Join-Path $pocRoot 'scripts/Copilot.Data.psm1'), $PSCommandPath)) {
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        Assert-True (@($errors).Count -eq 0) "PowerShell syntax: $path"
    }

    $a = Join-Path $work 'synthetic-a'
    $b = Join-Path $work 'synthetic-b'
    $result = & $build -UsersPath $fixtureUsers -UsagePath $fixtureUsage -OutputDirectory $a -DataClass synthetic
    $powerShell = (Get-Process -Id $PID).Path
    & $powerShell -NoProfile -File $build -UsersPath $fixtureUsers -UsagePath $fixtureUsage -OutputDirectory $b -DataClass synthetic | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Independent-process reproducibility build succeeded'
    Assert-True ($result.Status -eq 'success' -and $result.SourceRows -eq 3 -and $result.DepartmentCount -eq 2) 'Synthetic build result'
    $summary = Read-Json (Join-Path $a 'summary.json')
    $manifest = Read-Json (Join-Path $a 'manifest.json')
    Assert-True ($summary.totals.knownPromptsSubmitted -eq 20 -and $summary.totals.unknownPromptUsers -eq 1 -and $null -eq $summary.totals.promptsSubmitted) 'Unknown is null, known sum is 20'
    Assert-True ($manifest.syntheticFixtureAllowlistVerified -and $manifest.distributionAllowed -and $manifest.reconciliationPassed) 'Synthetic fixture/reconciliation gates'
    Assert-True ($manifest.sourceRows -eq 3 -and $manifest.quarantinedRows -eq 0) 'Source counts'
    Assert-True ($manifest.promptColumn -eq 'All Apps Copilot Prompts Submitted') 'Explicit provisional prompt column'
    $files = @(Get-ChildItem -LiteralPath $a -File -Recurse)
    Assert-True ($manifest.files.Count -eq $files.Count - 1) 'All generated files except manifest are hashed'
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($a, $file.FullName)
        $copy = Join-Path $b $relative
        Assert-True ((Get-FileHash -LiteralPath $file.FullName).Hash -eq (Get-FileHash -LiteralPath $copy).Hash) "Byte reproducibility: $relative"
        if ($file.Name -ne 'manifest.json') {
            $entry = @($manifest.files | Where-Object path -CEQ $relative.Replace('\', '/'))
            Assert-True ($entry.Count -eq 1 -and $entry[0].sha256 -ceq (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()) "Manifest digest: $relative"
        }
    }
    foreach ($dept in $summary.departments) {
        Assert-True ($dept.slug -cmatch '^dept-[a-f0-9]{64}$') 'Only hash-derived department paths'
        $rows = @(Import-Csv -LiteralPath (Join-Path $a "$($dept.slug)\usage.csv"))
        Assert-True ($rows.Count -eq $dept.metrics.reportUsers) 'Department row count'
        Assert-True (@($rows | Where-Object Department -CNE $dept.department).Count -eq 0) 'Zero department contamination'
        $html = Get-Content -LiteralPath (Join-Path $a "$($dept.slug)\index.html") -Raw -Encoding UTF8
        $otherUpns = @(Get-FixtureUsage | Where-Object { $_.'User Principal Name' -notin $rows.'User Principal Name' } | ForEach-Object { $_.'User Principal Name' })
        foreach ($upn in $otherUpns) { Assert-True (-not $html.Contains($upn)) 'Other department UPN absent from HTML' }
        Assert-True ($html -notmatch '(<script[^>]+src|<link\b|<iframe\b|<object\b|\bfetch\s*\(|localStorage|sessionStorage|indexedDB|document\.cookie|XMLHttpRequest|WebSocket|@import|type=.module)') 'Offline sandbox-safe HTML'
        Assert-True ([regex]::Matches($html, '<script>').Count -eq 2) 'Only theme and fixed UI translation scripts; no data script'
        Assert-True ($html.Contains('--cp-highlight:') -and $html.Contains('var(--cp-bg)') -and $html.Contains('"Segoe UI"')) 'Clawpilot theme and font'
        Assert-JapaneseUi $html
        Assert-True ($html.Contains('部門別レポート') -and $html.Contains([Net.WebUtility]::HtmlEncode($dept.department))) 'Department view is Japanese; source department is unchanged'
        Assert-True (-not $html.Contains('data-ja="' + [Net.WebUtility]::HtmlEncode($dept.department) + '"')) 'Department is not registered as a translation label'
    }
    $aggregateJson = Get-Content -LiteralPath (Join-Path $a 'summary.json') -Raw
    Assert-True ($aggregateJson -notmatch '@example\.invalid|Demo Alice|Demo Bob|Demo Carol') 'Summary contains aggregates only'
    Assert-True ((Get-Content -LiteralPath (Join-Path $a 'index.html') -Raw).Contains('ADMIN ONLY')) 'Root page administrator warning'
    $rootHtml = Get-Content -LiteralPath (Join-Path $a 'index.html') -Raw -Encoding UTF8
    Assert-JapaneseUi $rootHtml
    Assert-True ($rootHtml.Contains('管理者専用：全部門の情報を含みます。このページを部門向けに配布しないでください。')) 'Administrator distribution warning visible initially'
    Assert-True ($rootHtml.Contains('管理者向け・全部門') -and $rootHtml.Contains('隔離ユーザー数')) 'Administrator scope is Japanese'
    Assert-True ($rootHtml -match '取得済みプロンプト数の合計</span></dt><dd>20</dd>' -and
        $rootHtml -match 'プロンプト数が不明のユーザー</span></dt><dd>1</dd>') 'Cards use known sum and unknown count, not inferred zero totals'
    Assert-Throws { & $build -UsersPath $fixtureUsers -UsagePath $fixtureUsage -OutputDirectory $a -DataClass synthetic } 'must be empty'

    $users = Get-FixtureUsers
    $users[0].userPrincipalName = '  ALICE@EXAMPLE.INVALID  '
    $usage = Get-FixtureUsage
    $usage[0].'User Principal Name' = '  aLiCe@example.invalid '
    $caseParameters = Write-TestInput $users $usage
    $r = & $build @caseParameters
    Assert-True ($r.SourceRows -eq 3 -and $r.QuarantinedRows -eq 0) 'Case-insensitive trimmed UPN join / JSON array input'
    $tenantHtml = Get-Content -LiteralPath (Join-Path $caseParameters.OutputDirectory 'index.html') -Raw -Encoding UTF8
    Assert-True ($tenantHtml.Contains('出典：呼び出し元が提供したMicrosoft Graphユーザー情報') -and
        $tenantHtml.Contains('対象テナントや取得完了は確認しません。') -and
        -not $tenantHtml.Contains('検査用サンプル（合成データ）です。')) 'Tenant mode states input provenance without claiming live authentication or synthetic evidence'
    Assert-True ($tenantHtml.Contains('<strong>2026-10-27</strong>') -and
        $tenantHtml.Contains('管理者専用：全部門の情報を含みます。')) 'Tenant reference date and administrator scope are visible in Japanese'

    foreach ($invalid in @('-1', 'NaN', 'Infinity', '1.2', '1e3', '+2', '9223372036854775808', '=1+1')) {
        $usage = Get-FixtureUsage
        $usage[0].'All Apps Copilot Prompts Submitted' = $invalid
        $caseParameters = Write-TestInput (Get-FixtureUsers) $usage
        Assert-Throws { & $build @caseParameters } 'Invalid prompt count'
        Assert-True (-not (Test-Path -LiteralPath $caseParameters.OutputDirectory)) 'Invalid input emits no distribution artifacts'
    }
    $usage = Get-FixtureUsage
    $usage[2].'All Apps Copilot Prompts Submitted' = '0'
    $caseParameters = Write-TestInput (Get-FixtureUsers) $usage
    & $build @caseParameters | Out-Null
    $s = Read-Json (Join-Path $caseParameters.OutputDirectory 'summary.json')
    Assert-True ($s.totals.promptsSubmitted -eq 20 -and $s.totals.unknownPromptUsers -eq 0) 'Explicit zero differs from unknown'

    $usage = @(Get-FixtureUsage | Select-Object -Property * -ExcludeProperty 'All Apps Copilot Prompts Submitted')
    $caseParameters = Write-TestInput (Get-FixtureUsers) $usage
    & $build @caseParameters | Out-Null
    $s = Read-Json (Join-Path $caseParameters.OutputDirectory 'summary.json')
    $m = Read-Json (Join-Path $caseParameters.OutputDirectory 'manifest.json')
    Assert-True ($null -eq $s.totals.promptsSubmitted -and $s.totals.unknownPromptUsers -eq 3 -and $null -eq $m.promptColumn) 'Missing metric stays unknown, not last activity or zero'

    foreach ($period in @('7', '28')) {
        $usage = @(Get-FixtureUsage | ForEach-Object {
            $_.'Report Period' = $period
            $_ | Add-Member -NotePropertyName 'Prompts submitted for All Apps' -NotePropertyValue $_.'All Apps Copilot Prompts Submitted'
            $_ | Add-Member -NotePropertyName 'Prompts submitted for Copilot Chat (work)' -NotePropertyValue '99'
            $_ | Add-Member -NotePropertyName 'Prompts submitted for Copilot Chat (web)' -NotePropertyValue '88'
            $_ | Add-Member -NotePropertyName 'Active Usage Days for All Apps' -NotePropertyValue '6'
            $_
        })
        $usage = @($usage | Select-Object -Property * -ExcludeProperty 'All Apps Copilot Prompts Submitted')
        $caseParameters = Write-TestInput (Get-FixtureUsers) $usage
        & $build @caseParameters | Out-Null
        $s = Read-Json (Join-Path $caseParameters.OutputDirectory 'summary.json')
        $m = Read-Json (Join-Path $caseParameters.OutputDirectory 'manifest.json')
        Assert-True ($s.reportPeriod -eq $period -and $s.totals.knownPromptsSubmitted -eq 20 -and $s.totals.unknownPromptUsers -eq 1) "Live D$period alias totals; app counts/activity days excluded"
        Assert-True ($m.promptColumn -ceq 'Prompts submitted for All Apps' -and $m.promptColumnsPresent.Count -eq 1) 'Manifest identifies actual source column'
    }
    foreach ($mode in @('equal', 'conflicting', 'fallback', 'invalid', 'zeroConflict')) {
        $usage = @(Get-FixtureUsage | ForEach-Object {
            $_ | Add-Member -NotePropertyName 'Prompts submitted for All Apps' -NotePropertyValue $_.'All Apps Copilot Prompts Submitted'
            $_
        })
        switch ($mode) {
            'equal' { $usage[0].'Prompts submitted for All Apps' = '0012' }
            'conflicting' { $usage[0].'Prompts submitted for All Apps' = '13' }
            'fallback' {
                $usage[0].'Prompts submitted for All Apps' = ''
                $usage[1].'All Apps Copilot Prompts Submitted' = ''
            }
            'invalid' { $usage[0].'All Apps Copilot Prompts Submitted' = '-1' }
            'zeroConflict' { $usage[0].'Prompts submitted for All Apps' = '0' }
        }
        $caseParameters = Write-TestInput (Get-FixtureUsers) $usage
        if ($mode -in @('conflicting', 'zeroConflict')) {
            Assert-Throws { & $build @caseParameters } 'Conflicting total prompt aliases'
            Assert-True (-not (Test-Path -LiteralPath $caseParameters.OutputDirectory)) 'Alias conflict fails before output'
        }
        elseif ($mode -eq 'invalid') {
            Assert-Throws { & $build @caseParameters } 'Invalid prompt count'
        }
        else {
            & $build @caseParameters | Out-Null
            $s = Read-Json (Join-Path $caseParameters.OutputDirectory 'summary.json')
            $m = Read-Json (Join-Path $caseParameters.OutputDirectory 'manifest.json')
            Assert-True ($s.totals.knownPromptsSubmitted -eq 20 -and $s.totals.unknownPromptUsers -eq 1) "Aliases counted once: $mode"
            Assert-True ($m.promptColumnsPresent.Count -eq 2) 'Both aliases recorded without summing'
        }
    }

    $users = Get-FixtureUsers
    $users[1].userPrincipalName = ' ALICE@EXAMPLE.INVALID '
    $caseParameters = Write-TestInput $users (Get-FixtureUsage)
    Assert-Throws { & $build @caseParameters } 'Duplicate directory UPN'
    $usage = Get-FixtureUsage
    $usage[1].'User Principal Name' = ' ALICE@EXAMPLE.INVALID '
    $caseParameters = Write-TestInput (Get-FixtureUsers) $usage
    Assert-Throws { & $build @caseParameters } 'Duplicate usage UPN'
    $usage[1].'Report Period' = '7'
    $caseParameters = Write-TestInput (Get-FixtureUsers) $usage
    Assert-Throws { & $build @caseParameters } 'Duplicate usage UPN'
    $usage = Get-FixtureUsage
    $usage[1].'Report Period' = '7'
    $caseParameters = Write-TestInput (Get-FixtureUsers) $usage
    Assert-Throws { & $build @caseParameters } 'Mixed report periods'
    $usage = Get-FixtureUsage
    $usage[1].'Report Refresh Date' = '2026-10-26'
    $caseParameters = Write-TestInput (Get-FixtureUsers) $usage
    Assert-Throws { & $build @caseParameters } 'Mixed report periods or refresh'

    $users = Get-FixtureUsers
    $users[0].department = $null
    $usage = Get-FixtureUsage
    $usage[1].'User Principal Name' = 'unmatched@example.invalid'
    $usage[2].'User Principal Name' = 'anonymous-id-123'
    $caseParameters = Write-TestInput $users $usage
    Assert-Throws { & $build @caseParameters } 'Distribution blocked'
    Assert-True (-not (Test-Path -LiteralPath $caseParameters.OutputDirectory)) 'Default quarantine failure creates no report'
    $r = & $build @caseParameters -AllowUnmatched
    $m = Read-Json (Join-Path $caseParameters.OutputDirectory 'manifest.json')
    $s = Read-Json (Join-Path $caseParameters.OutputDirectory 'summary.json')
    Assert-True ($r.Status -eq 'partial' -and -not $r.DistributionAllowed) 'Partial success never claims distribution readiness'
    $partialHtml = Get-Content -LiteralPath (Join-Path $caseParameters.OutputDirectory 'index.html') -Raw -Encoding UTF8
    Assert-True ($partialHtml.Contains('配布は禁止です。') -and $partialHtml.Contains('実テナントデータ：')) 'Tenant partial output visibly blocks distribution in Japanese'
    Assert-True ($m.quarantinedRows -eq 3 -and $m.matchedRows -eq 0 -and $m.quarantineReasons.departmentMissing -eq 1 -and $m.quarantineReasons.unmatchedUpn -eq 1 -and $m.quarantineReasons.anonymousOrInvalidUpn -eq 1) 'Quarantine reason counts reconcile'
    Assert-True ($s.quarantined.knownPromptsSubmitted -eq 20 -and $s.totals.reportUsers -eq 3) 'Quarantine numeric sums retained'
    Assert-True (@(Import-Csv -LiteralPath (Join-Path $caseParameters.OutputDirectory 'quarantine\usage.csv')).Count -eq 3) 'Quarantine detail is separate'

    $usage = Get-FixtureUsage
    $usage[2].'User Principal Name' = 'missing@example.invalid'
    $caseParameters = Write-TestInput (Get-FixtureUsers) $usage
    & $build @caseParameters -AllowUnmatched | Out-Null
    $s = Read-Json (Join-Path $caseParameters.OutputDirectory 'summary.json')
    Assert-True ($s.matched.reportUsers -eq 2 -and $s.quarantined.reportUsers -eq 1 -and $s.departments.Count -eq 2) 'Mixed matched/quarantined source reconciles'
    foreach ($dept in $s.departments) {
        Assert-True (-not (Get-Content -LiteralPath (Join-Path $caseParameters.OutputDirectory "$($dept.slug)\usage.csv") -Raw).Contains('missing@example.invalid')) 'Quarantine never enters department distribution'
    }

    $users = Get-FixtureUsers
    $users[0].department = '../../<script>alert(1)</script>{{TABLE}}'
    $usage = Get-FixtureUsage
    $usage[0].'Display Name' = '<img src=x onerror=alert(1)>{{TITLE}}</script>'
    $usage[1].'Display Name' = ' =HYPERLINK("https://example.invalid","demo")'
    $usage[2].'Display Name' = "`t+SUM(1,2)"
    $caseParameters = Write-TestInput $users $usage
    & $build @caseParameters | Out-Null
    $s = Read-Json (Join-Path $caseParameters.OutputDirectory 'summary.json')
    $d = @($s.departments | Where-Object department -CLike '../../*')[0]
    Assert-True ($d.slug -cmatch '^dept-[a-f0-9]{64}$') 'Path traversal in department cannot control paths'
    $html = Get-Content -LiteralPath (Join-Path $caseParameters.OutputDirectory "$($d.slug)\index.html") -Raw
    Assert-True ($html.Contains('&lt;img') -and $html.Contains('&lt;script&gt;') -and -not $html.Contains('<img')) 'HTML injection is encoded'
    Assert-True ($html.Contains('{{TITLE}}') -and $html.Contains('{{TABLE}}')) 'Inserted data is not re-templated'
    Assert-True ([regex]::Matches($html, '<script>').Count -eq 2) 'Injection cannot add script beyond theme and translation'
    Assert-True (-not $html.Contains('data-ja="&lt;img') -and -not $html.Contains('data-ja="../../')) 'Source data cannot register translations'
    $allExportRows = @($s.departments | ForEach-Object { Import-Csv -LiteralPath (Join-Path $caseParameters.OutputDirectory "$($_.slug)\usage.csv") })
    $bob = @($allExportRows | Where-Object 'User Principal Name' -EQ 'bob@example.invalid')[0]
    $carol = @($allExportRows | Where-Object 'User Principal Name' -EQ 'carol@example.invalid')[0]
    Assert-True ($bob.'Display Name'.StartsWith("' =HYPERLINK") -and $carol.'Display Name'.StartsWith("'`t+SUM")) 'CSV formula/control prefixes are neutralized'
    Assert-True ($s.totals.knownPromptsSubmitted -eq 20) 'Display sanitization does not modify aggregates'

    foreach ($prefix in @('=1', '+1', '-1', '@SUM(1)', "`r=1", "`n=1")) {
        $usage = Get-FixtureUsage
        $usage[0].'Display Name' = $prefix
        $caseParameters = Write-TestInput (Get-FixtureUsers) $usage
        & $build @caseParameters | Out-Null
        $s = Read-Json (Join-Path $caseParameters.OutputDirectory 'summary.json')
        $dept = @($s.departments | Where-Object department -EQ 'Sales')[0]
        $export = @(Import-Csv -LiteralPath (Join-Path $caseParameters.OutputDirectory "$($dept.slug)\usage.csv"))
        Assert-True ($export[0].'Display Name'.StartsWith("'")) "CSV injection prefix: $prefix"
    }

    foreach ($required in @('User Principal Name', 'Report Refresh Date', 'Report Period')) {
        $usage = @(Get-FixtureUsage | Select-Object -Property * -ExcludeProperty $required)
        $caseParameters = Write-TestInput (Get-FixtureUsers) $usage
        Assert-Throws { & $build @caseParameters } 'Missing required CSV column'
    }
    $caseParameters = Write-TestInput @() (Get-FixtureUsage)
    Assert-Throws { & $build @caseParameters } 'Empty directory'
    $caseParameters = Write-TestInput (Get-FixtureUsers) @()
    Assert-Throws { & $build @caseParameters } 'Empty usage'
    $caseParameters = Write-TestInput (Get-FixtureUsers) (Get-FixtureUsage)
    [IO.File]::WriteAllText($caseParameters.UsagePath, ((Get-Content -LiteralPath $fixtureUsage -TotalCount 1) + "`n"))
    Assert-Throws { & $build @caseParameters } 'Empty usage'
    $caseParameters = Write-TestInput (Get-FixtureUsers) (Get-FixtureUsage)
    [IO.File]::WriteAllText($caseParameters.UsagePath, (Get-Content -LiteralPath $fixtureUsage -Raw) + "extra,column`n")
    Assert-Throws { & $build @caseParameters } 'field count'
    $caseParameters = Write-TestInput (Get-FixtureUsers) (Get-FixtureUsage)
    [IO.File]::WriteAllText($caseParameters.UsagePath, "User Principal Name,User Principal Name,Report Refresh Date,Report Period`na,a,2026-10-27,30`n")
    Assert-Throws { & $build @caseParameters } 'duplicate CSV header'
    $caseParameters = Write-TestInput (Get-FixtureUsers) (Get-FixtureUsage)
    [IO.File]::WriteAllText($caseParameters.UsersPath, '{"value": [], "@odata.nextLink": "https://example.invalid/next"}')
    Assert-Throws { & $build @caseParameters } 'pagination is incomplete'
    foreach ($field in @('Report Refresh Date', 'Report Period', 'Word Copilot Last Activity Date')) {
        $usage = Get-FixtureUsage
        $usage[0].$field = 'invalid'
        $caseParameters = Write-TestInput (Get-FixtureUsers) $usage
        Assert-Throws { & $build @caseParameters } 'Invalid (Report|activity)'
    }

    $caseParameters = Write-TestInput (Get-FixtureUsers) (Get-FixtureUsage)
    $caseParameters.DataClass = 'synthetic'
    Assert-Throws { & $build @caseParameters } 'fixture allowlist'
    $users = Get-FixtureUsers
    $users[0].userPrincipalName = 'real-user@example.invalid'
    $caseParameters = Write-TestInput $users (Get-FixtureUsage)
    $caseParameters.DataClass = 'synthetic'
    Assert-Throws { & $build @caseParameters } 'fixture allowlist'
    Assert-Throws { & $build -UsersPath $fixtureUsers -UsagePath $fixtureUsage -OutputDirectory (Join-Path $work 'exports\tenant') -DataClass tenant } 'forbidden in exports'
    Assert-Throws { & $build -UsersPath $fixtureUsers -UsagePath $fixtureUsage -OutputDirectory (Join-Path $pocRoot 'tests\tenant-disallowed') -DataClass tenant } 'requires workspace .local or RUNNER_TEMP'
    Assert-Throws { & $build -UsersPath $fixtureUsers -UsagePath $fixtureUsage -OutputDirectory "$work\safe\..\escape" -DataClass tenant } 'parent traversal'
    $linkTarget = Join-Path $work 'link-target'
    $linkPath = Join-Path $work 'output-junction'
    [void][IO.Directory]::CreateDirectory($linkTarget)
    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $linkType -Path $linkPath -Target $linkTarget | Out-Null
    Assert-Throws { & $build -UsersPath $fixtureUsers -UsagePath $fixtureUsage -OutputDirectory "$linkPath\report" -DataClass tenant } 'reparse-point'
    [IO.Directory]::Delete($linkPath)

    Import-Module (Join-Path $pocRoot 'scripts/Copilot.Data.psm1') -Force
    $measurement = Measure-CopilotSourceUsage -Rows (Get-FixtureUsage)
    Assert-True ($measurement.SourceRows -eq 3 -and $measurement.KnownPromptRows -eq 2 -and
        $measurement.UnknownPromptRows -eq 1 -and $measurement.KnownPromptTotal -eq 20) 'Source-only counts and known sum'
    Assert-True ($measurement.ReportRefreshDate -ceq '2026-10-27' -and $measurement.ReportPeriod -ceq '30') 'Source-only report snapshot'
    Assert-True ($measurement.ObservationScope -ceq 'source-only' -and -not $measurement.DistributionAllowed) 'Source observation does not permit distribution'
    $allowedKeys = @('SourceRows', 'KnownPromptRows', 'UnknownPromptRows', 'KnownPromptTotal', 'ReportRefreshDate', 'ReportPeriod', 'ObservationScope', 'DistributionAllowed')
    Assert-True (($measurement.PSObject.Properties.Name -join ',') -ceq ($allowedKeys -join ',')) 'Exact aggregate-only return schema'
    Assert-True (($measurement | ConvertTo-Json -Compress) -notmatch 'example\.invalid|Alice|Sales|Engineering') 'Source result discloses no personal identifiers'

    foreach ($period in @('7', '28')) {
        $sourceRows = @(
            [pscustomobject]@{ 'Report Refresh Date' = '2026-10-27'; 'Report Period' = $period; 'Prompts submitted for All Apps' = '0'; 'Prompts submitted for Copilot Chat (work)' = '999'; 'Active Usage Days for All Apps' = '7' },
            [pscustomobject]@{ 'Report Refresh Date' = '2026-10-27'; 'Report Period' = $period; 'Prompts submitted for All Apps' = '' }
        )
        $measurement = Measure-CopilotSourceUsage -Rows $sourceRows
        Assert-True ($measurement.KnownPromptRows -eq 1 -and $measurement.UnknownPromptRows -eq 1 -and
            $null -ne $measurement.KnownPromptTotal -and $measurement.KnownPromptTotal -eq 0 -and
            $measurement.ReportPeriod -ceq $period) "D$period real alias: explicit known zero and unknown differ; no identity required"
    }
    $sourceRows = @(
        [pscustomobject]@{ 'Report Refresh Date' = '2026-10-27'; 'Report Period' = '7'; 'Prompts submitted for All Apps' = '' },
        [pscustomobject]@{ 'Report Refresh Date' = '2026-10-27'; 'Report Period' = '7' }
    )
    $measurement = Measure-CopilotSourceUsage -Rows $sourceRows
    Assert-True ($measurement.KnownPromptRows -eq 0 -and $measurement.UnknownPromptRows -eq 2 -and
        $null -eq $measurement.KnownPromptTotal) 'No known source rows means null total, not zero'

    foreach ($mode in @('equal', 'conflict', 'fallback', 'invalidSecondAlias', 'maximum')) {
        $row = [ordered]@{ 'Report Refresh Date' = '2026-10-27'; 'Report Period' = '7'
            'Prompts submitted for All Apps' = '12'; 'All Apps Copilot Prompts Submitted' = '0012' }
        switch ($mode) {
            'conflict' { $row['All Apps Copilot Prompts Submitted'] = '13' }
            'fallback' { $row['Prompts submitted for All Apps'] = '' }
            'invalidSecondAlias' { $row['All Apps Copilot Prompts Submitted'] = '-1' }
            'maximum' {
                $row['Prompts submitted for All Apps'] = '9223372036854775807'
                $row['All Apps Copilot Prompts Submitted'] = '9223372036854775807'
            }
        }
        if ($mode -eq 'conflict') {
            Assert-Throws { Measure-CopilotSourceUsage -Rows @([pscustomobject]$row) } 'Conflicting total prompt aliases'
        }
        elseif ($mode -eq 'invalidSecondAlias') {
            Assert-Throws { Measure-CopilotSourceUsage -Rows @([pscustomobject]$row) } 'Invalid prompt count'
        }
        else {
            $measurement = Measure-CopilotSourceUsage -Rows @([pscustomobject]$row, [pscustomobject]$row)
            $expected = if ($mode -eq 'maximum') { [decimal]'18446744073709551614' } else { [decimal]24 }
            Assert-True ($measurement.KnownPromptTotal -eq $expected -and $measurement.KnownPromptRows -eq 2) "Shared alias parser, no double count, decimal sum avoids Int64 total overflow: $mode"
        }
    }
    foreach ($invalid in @('-1', 'NaN', 'Infinity', '1.2', '1e3', '+2', '9223372036854775808', '=1+1')) {
        $row = [pscustomobject]@{ 'Report Refresh Date' = '2026-10-27'; 'Report Period' = '7'; 'Prompts submitted for All Apps' = $invalid }
        Assert-Throws { Measure-CopilotSourceUsage -Rows @($row) } 'Invalid prompt count'
    }
    foreach ($field in @('Report Refresh Date', 'Report Period')) {
        $sourceRows = @(Get-FixtureUsage)
        $sourceRows[1].$field = if ($field -eq 'Report Period') { '7' } else { '2026-10-26' }
        Assert-Throws { Measure-CopilotSourceUsage -Rows $sourceRows } 'Mixed report periods or refresh snapshots'
        $sourceRows[1].$field = 'invalid'
        Assert-Throws { Measure-CopilotSourceUsage -Rows $sourceRows } 'Invalid Report'
        $sourceRows = @(Get-FixtureUsage | Select-Object -Property * -ExcludeProperty $field)
        Assert-Throws { Measure-CopilotSourceUsage -Rows $sourceRows } 'Missing required CSV column'
    }
    Assert-Throws { Measure-CopilotSourceUsage -Rows @() } 'Empty usage'
    Assert-Throws { Measure-CopilotSourceUsage -Rows $null } 'Empty usage'
    Assert-Throws { Measure-CopilotSourceUsage -Rows @($null) } 'Invalid source row'
    $identityTrap = [pscustomobject]@{ 'Report Refresh Date' = '2026-10-27'; 'Report Period' = '7'; 'Prompts submitted for All Apps' = '1' }
    $identityTrap | Add-Member -MemberType ScriptProperty -Name 'User Principal Name' -Value { throw 'Identifiers must not be accessed' }
    $identityTrap | Add-Member -MemberType ScriptProperty -Name 'Display Name' -Value { throw 'Identifiers must not be accessed' }
    $measurement = Measure-CopilotSourceUsage -Rows @($identityTrap)
    Assert-True ($measurement.KnownPromptTotal -eq 1) 'Source aggregate never reads identity properties'
    Write-Output "PASS: $script:Assertions assertions; deterministic builds, joins, isolation, UI, source-only aggregates, shared aliases/unknown/overflow, malformed inputs, output boundaries, HTML/CSV injection."
}
finally {
    $env:RUNNER_TEMP = $oldRunnerTemp
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
