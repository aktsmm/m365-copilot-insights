#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../scripts/Copilot.MonthlyPublish.psm1') -Force
$utf8 = [Text.UTF8Encoding]::new($false)
$checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Run-Scenario([string]$Mode, [bool]$Existing, [string]$RunKey='123-1') {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $store = @{}
    $calls = [Collections.Generic.List[object]]::new()
    $old = $utf8.GetBytes('{"old":"preserved"}')
    if ($Existing) {
        $store['CopilotMonthly/current.json'] = @{bytes=$old;etag='"version-1"';id='old-current';folder=$false}
    }
    $state = @{store=$store;calls=$calls;mode=$Mode;sequence=0}
    $request = {
        param($method,$path,$bytes,$headers)
        $state.calls.Add(@{method=$method;path=$path;headers=$headers})
        $content = $path.EndsWith(':/content')
        $relative = $path -replace '^/root:/','' -replace ':(/content|/children)$',''
        $relative = [uri]::UnescapeDataString($relative)
        function Reply([int]$Status, $Value) {
            $data = if ($Value -is [byte[]]) { $Value } else { $utf8.GetBytes(($Value | ConvertTo-Json -Depth 10 -Compress)) }
            return @{Status=$Status;Bytes=$data}
        }
        function Item($value,[string]$key) {
            $item = @{id=$value.id;name=$key.Split('/')[-1];eTag=$value.etag}
            if ($value.folder) { $item.folder=@{} } else { $item.file=@{}; $item.size=$value.bytes.Length }
            return $item
        }
        if ($method -eq 'GET') {
            if ($state.mode -eq 'current-denied' -and $relative -eq 'CopilotMonthly/current.json') { return (Reply 403 @{}) }
            if (-not $state.store.ContainsKey($relative)) { return (Reply 404 @{}) }
            $value = $state.store[$relative]
            if ($content) {
                if ($state.mode -eq 'corrupt-readback' -and $relative.EndsWith('/monthly.json')) {
                    return (Reply 200 $utf8.GetBytes('corrupt'))
                }
                return (Reply 200 $value.bytes)
            }
            return (Reply 200 (Item $value $relative))
        }
        if ($method -eq 'POST') {
            $body = $utf8.GetString($bytes) | ConvertFrom-Json
            $key = if ($path -eq '/root/children') { $body.name } else { "$relative/$($body.name)" }
            if ($state.store.ContainsKey($key)) { return (Reply 409 @{}) }
            $state.sequence++
            $value = @{id="folder-$($state.sequence)";etag='"folder-etag"';folder=$true}
            $state.store[$key]=$value
            return (Reply 201 (Item $value $key))
        }
        if ($method -ne 'PUT' -or -not $content) { throw 'Unexpected mocked transport call.' }
        if ($state.mode -eq 'current-conflict' -and $relative -eq 'CopilotMonthly/current.json') { return (Reply 412 @{}) }
        if ($state.mode -eq 'upload-failed' -and $relative.EndsWith('/monthly-dashboard.html')) { return (Reply 503 @{}) }
        $exists = $state.store.ContainsKey($relative)
        if ($state.mode -ne 'ignores-conditional') {
            if ($headers.ContainsKey('If-None-Match') -and $exists) { return (Reply 412 @{}) }
            if ($headers.ContainsKey('If-Match') -and (-not $exists -or $state.store[$relative].etag -cne $headers['If-Match'])) {
                return (Reply 412 @{})
            }
        }
        $state.sequence++
        $value = @{id="file-$($state.sequence)";etag="`"version-$($state.sequence)`"";bytes=[byte[]]$bytes;folder=$false}
        $state.store[$relative]=$value
        return (Reply $(if ($exists) { 200 } else { 201 }) (Item $value $relative))
    }.GetNewClosure()
    $artifacts = @{
        'monthly.json'=$utf8.GetBytes('{"schemaVersion":1,"dataClass":"synthetic"}')
        'manifest.json'=$utf8.GetBytes('{"schemaVersion":1}')
        'monthly-dashboard.html'=$utf8.GetBytes('<!doctype html><title>Fixture</title>')
        '2026-10-all-apps-actions.csv'=$utf8.GetBytes('upn,count')
    }
    $raw = @{'snapshot-2026-10-20.json'=$utf8.GetBytes('{"synthetic":true}')}
    $proof = @{}
    $failure = $null
    try {
        Publish-CopilotMonthlyFiles -Request $request -RunKey $RunKey -Artifacts $artifacts -RawArtifacts $raw -Proof $proof -Apply:($Mode -ne 'dry-run')
    } catch { $failure="$($_.Exception.Message)`n$($_.ScriptStackTrace)" }
    if ($Mode -eq 'dry-run') {
        Assert ($null -eq $failure -and $calls.Count -eq 0 -and -not $proof.complete) 'Dry-run made a network call.'
        return
    }
    if ($Mode -in @('success','stage-only','ignores-conditional')) {
        Assert ($null -eq $failure -and $proof.complete -and -not $proof.currentCommitted -and $proof.scope -ceq 'immutable-only') 'Stage-only publication failed.'
        Assert (@($calls | Where-Object { $_.method -eq 'PUT' -and $_.path -eq '/root:/CopilotMonthly/current.json:/content' }).Count -eq 0) 'Stage-only attempted current.'
        Assert ($store.ContainsKey("CopilotMonthlyRaw/$RunKey/publication-manifest.json")) 'Durable hash index is missing.'
        Assert (@($proof.files | Where-Object { -not $_.readbackVerified }).Count -eq 0) 'Stage-only uploaded unverified bytes.'
        if ($Existing) {
            Assert ([Convert]::ToBase64String($store['CopilotMonthly/current.json'].bytes) -ceq [Convert]::ToBase64String($old)) 'Stage-only changed existing current.'
        } else {
            Assert (-not $store.ContainsKey('CopilotMonthly/current.json')) 'Stage-only created current.'
        }
        $replay = @{}
        try {
            Publish-CopilotMonthlyFiles -Request $request -RunKey $RunKey -Artifacts $artifacts -RawArtifacts $raw -Proof $replay -Apply
            throw 'Unexpected replay success.'
        } catch { Assert ($_.Exception.Message -like '*no overwrite*') 'Replay must fail before replacing artifacts.' }
    } else {
        Assert ($null -ne $failure -and -not $proof.complete) "$Mode failure was hidden."
        Assert (-not $proof.currentCommitted) "$Mode advanced current."
        if ($Existing) {
            Assert ([Convert]::ToBase64String($store['CopilotMonthly/current.json'].bytes) -ceq [Convert]::ToBase64String($old)) "$Mode corrupted old current."
        } else {
            Assert (-not $store.ContainsKey('CopilotMonthly/current.json')) "$Mode created current."
        }
        if ($Mode -ne 'current-conflict') {
            Assert (@($calls | Where-Object { $_.method -eq 'PUT' -and $_.path -eq '/root:/CopilotMonthly/current.json:/content' }).Count -eq 0) "$Mode attempted current prematurely."
        }
        Assert (@($calls | Where-Object { $_.method -eq 'PUT' -and $_.path.EndsWith('/monthly-dashboard.html:/content') }).Count -le 1) 'Mutating request retried.'
    }
}
foreach ($existing in @($false,$true)) {
    foreach ($mode in @('success','stage-only','dry-run','corrupt-readback','upload-failed','ignores-conditional','current-denied')) {
        Run-Scenario $mode $existing
    }
}
$proof = @{}
Run-Scenario 'success' $true 'repo-12345-123-1'
Run-Scenario 'corrupt-readback' $true 'repo-12345-123-1'
try {
    Publish-CopilotMonthlyFiles -Request {throw 'Network must not run'} -RunKey '123-1' -Artifacts @{'../secret'=[byte[]]@(1)} -RawArtifacts @{'users.json'=[byte[]]@(1)} -Proof $proof -Apply
    throw 'Unexpected invalid path acceptance.'
} catch { Assert ($_.Exception.Message -like '*allowlist*') 'Invalid input reached network.' }
try {
    Publish-CopilotMonthlyFiles -Request {throw 'Network must not run'} -RunKey '123-1' -Artifacts @{'monthly.json'=[byte[]]@(1)} -RawArtifacts @{'users.json'=[byte[]]@(1)} -Proof @{} -SwitchCurrent -Apply
    throw 'Unexpected retired content PUT path acceptance.'
} catch { Assert ($_.Exception.Message -like '*retired*') 'Retired content PUT path was not blocked.' }
Write-Output "Monthly publisher: $checks checks passed (transport fixtures, not tenant/SPO proof)."
