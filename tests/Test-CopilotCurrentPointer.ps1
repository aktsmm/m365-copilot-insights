#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\scripts\Copilot.CurrentPointer.psm1') -Force
$checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Scenario([string]$Mode, [bool]$Existing, [string]$RunKey='123-1') {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $bootstrap = $utf8.GetBytes('{"schemaVersion":2,"pointerType":"list-item-title"}')
    $state = @{calls=[Collections.Generic.List[object]]::new();files=@{};items=@{};folder=$Existing;sequence=10;mode=$Mode}
    if ($Existing) {
        $state.files['CopilotMonthly/pointer/current.json'] = @{id='file1';bytes=$bootstrap}
        $state.items['1'] = @{id='1';eTag='"v1"';fields=@{Title='previous'}}
    }
    $request = {
        param($method,$path,$bytes,$headers)
        $state.calls.Add(@{method=$method;path=$path;headers=$headers})
        function Reply($Status,$Value) {
            $data = if ($Value -is [byte[]]) { $Value } else { $utf8.GetBytes(($Value | ConvertTo-Json -Compress -Depth 10)) }
            @{Status=$Status;Bytes=$data}
        }
        if ($path -match '^/list/items/([0-9]+)(.*)$') {
            $id=$Matches[1];$suffix=$Matches[2]
            if (-not $state.items.ContainsKey($id)) { return (Reply 404 @{}) }
            $item=$state.items[$id]
            if ($method -eq 'GET' -and $suffix -ceq '?$expand=fields') {
                return (Reply 200 $item)
            }
            if ($method -ne 'PATCH' -or $suffix -cne '/fields') { throw 'Unexpected library operation.' }
            if ($state.mode -eq 'denied') { return (Reply 403 @{}) }
            if ($id -ne '1' -and $state.mode -eq 'probe-ignored') {
                $item.fields.Title='incorrectly-overwritten'
                return (Reply 200 $item.fields)
            }
            if ($id -eq '1' -and $state.mode -eq 'conflict') {
                $item.eTag='"concurrent-winner"';$item.fields.Title='another-winner'
                return (Reply 412 @{})
            }
            if ($headers['If-Match'] -cne $item.eTag) { return (Reply 412 @{}) }
            $body=$utf8.GetString($bytes)|ConvertFrom-Json
            $item.fields.Title=$body.Title
            $state.sequence++
            $item.eTag="`"v$($state.sequence)`""
            if ($id -eq '1' -and $state.mode -eq 'ambiguous') { return (Reply 503 @{}) }
            if ($id -eq '1' -and $state.mode -eq 'readback-drift') { $item.fields.Title='changed-after-success' }
            return (Reply 200 $item.fields)
        }
        if ($path -match '^/items/file([0-9]+)/listItem$') { return (Reply 200 @{id=$Matches[1]}) }
        if ($method -eq 'POST') {
            if ($state.folder) { return (Reply 409 @{}) }
            $state.folder=$true
            return (Reply 201 @{id='folder1';name='pointer'})
        }
        $relative=$path -replace '^/root:/','' -replace ':/content$',''
        if ($method -eq 'GET' -and $relative -eq 'CopilotMonthly') { return (Reply 200 @{id='root';folder=@{}}) }
        if ($method -eq 'GET') {
            if (-not $state.files.ContainsKey($relative)) { return (Reply 404 @{}) }
            $file=$state.files[$relative]
            if ($path.EndsWith(':/content')) {
                if ($state.mode -eq 'bad-bootstrap' -and $relative.EndsWith('/pointer/current.json')) { return (Reply 200 $utf8.GetBytes('{}')) }
                return (Reply 200 $file.bytes)
            }
            return (Reply 200 @{id=$file.id;file=@{}})
        }
        if ($method -eq 'PUT') {
            if ($state.files.ContainsKey($relative)) { throw 'Pointer bootstrap was overwritten.' }
            $id=if ($relative.EndsWith('/pointer/current.json')) {'1'} else {'2'}
            $state.files[$relative]=@{id="file$id";bytes=$bytes}
            $state.items[$id]=@{id=$id;eTag='"v1"';fields=@{}}
            return (Reply 201 @{id="file$id";size=$bytes.Length;name=$relative.Split('/')[-1]})
        }
        throw 'Unexpected fixture operation.'
    }.GetNewClosure()
    $proof=@{complete=$true;files=@(@{readbackVerified=$true});currentCommitted=$false}
    $errorText=$null
    try {
        $before=Initialize-CopilotCurrentPointer -Request $request -Proof $proof
        Set-CopilotCurrentPointer -Request $request -Before $before -RunKey $RunKey -PayloadSha256 ('a'*64) -Proof $proof
    } catch { $errorText=$_.Exception.Message }
    if ($Mode -eq 'success') {
        Assert ($null -eq $errorText -and $proof.complete -and $proof.currentCommitted) "CAS success failed: $errorText"
        Assert (($proof.metadataProbe.statuses -join ',') -ceq '412,200,412') 'Probe did not cover stale/valid/reused ETag.'
        $title=$state.items['1'].fields.Title|ConvertFrom-Json
        Assert ($title.schemaVersion -eq 1 -and $title.dataPath -ceq "Shared Documents/CopilotMonthly/$RunKey/monthly.json" -and $title.sha256 -ceq ('a'*64)) 'Current manifest mismatch.'
        Assert ($state.items['1'].fields.Title.Length -le 255) 'Title limit exceeded.'
    } else {
        Assert ($null -ne $errorText -and -not $proof.currentCommitted) "$Mode failure hidden."
        if ($Mode -in @('probe-ignored','denied','bad-bootstrap')) {
            Assert (@($state.calls|Where-Object {$_.method -eq 'PATCH' -and $_.path -eq '/list/items/1/fields'}).Count -eq 0) "$Mode attempted current."
        }
        if ($Mode -eq 'conflict') { Assert ($state.items['1'].fields.Title -ceq 'another-winner') 'Conflict overwrote the winner.' }
    }
    Assert (@($state.calls|Where-Object {$_.method -eq 'PATCH' -and $_.path -eq '/list/items/1/fields'}).Count -le 1) 'Current update was retried.'
    Assert (@($state.calls|Where-Object {$_.method -eq 'PUT' -and $_.path -eq '/root:/CopilotMonthly/current.json:/content'}).Count -eq 0) 'Retired current content was written.'
}
foreach ($existing in @($false,$true)) {
    foreach ($mode in @('success','probe-ignored','denied','conflict','ambiguous','readback-drift')) { Scenario $mode $existing }
}
Scenario 'bad-bootstrap' $true
Scenario 'success' $true 'repo-12345-123-1'
Scenario 'conflict' $true 'repo-12345-123-1'
Write-Output "Current metadata pointer: $checks fixture checks passed (not tenant proof)."
