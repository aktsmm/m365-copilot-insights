Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-CopilotPointerItem {
    param([Parameter(Mandatory)][scriptblock]$Request, [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]*$')][string]$ItemId)
    $reply = & $Request 'GET' "/list/items/$ItemId`?`$expand=fields" $null @{}
    if ($reply.Status -ne 200) { throw "Pointer item read failed: HTTP $($reply.Status)." }
    $item = [Text.Encoding]::UTF8.GetString($reply.Bytes) | ConvertFrom-Json -AsHashtable -DateKind String
    if ($item.id -cne $ItemId -or $item.eTag -isnot [string] -or [string]::IsNullOrWhiteSpace($item.eTag) -or
        $item.eTag -match '[\r\n]' -or -not $item.ContainsKey('fields')) { throw 'Pointer item schema is invalid.' }
    $title = if ($item.fields.ContainsKey('Title')) { $item.fields.Title } else { '' }
    if ($null -eq $title) { $title = '' }
    if ($title -isnot [string] -or $title.Length -gt 255) { throw 'Pointer title exceeds its bounded text contract.' }
    return @{ itemId=$ItemId; eTag=$item.eTag; title=$title }
}

function New-CopilotPointerFile {
    param(
        [Parameter(Mandatory)][scriptblock]$Request,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][hashtable]$Proof
    )
    $entry = @{ path=$Path; state='creating'; readbackVerified=$false }
    $Proof.pointerItems += @($entry)
    $reply = & $Request 'PUT' "/root:/$Path`:/content" $Bytes @{}
    $entry.httpStatus = $reply.Status
    if ($reply.Status -ne 201) { throw "New pointer file creation uncertain: HTTP $($reply.Status); never replay." }
    $item = [Text.Encoding]::UTF8.GetString($reply.Bytes) | ConvertFrom-Json -AsHashtable
    if (-not $item.id -or $item.name -cne $Path.Split('/')[-1] -or $item.size -ne $Bytes.Length) { throw 'Pointer file metadata mismatch.' }
    $entry.itemId = $item.id
    $entry.state = 'created'
    $read = & $Request 'GET' "/root:/$Path`:/content" $null @{}
    $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    if ($read.Status -ne 200 -or $read.Bytes.Length -ne $Bytes.Length -or
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($read.Bytes)).ToLowerInvariant() -cne $sha) {
        throw 'Pointer bootstrap bytes failed readback.'
    }
    $entry.sha256 = $sha
    $entry.readbackVerified = $true
    return $item.id
}

function Initialize-CopilotCurrentPointer {
    param([Parameter(Mandatory)][scriptblock]$Request, [Parameter(Mandatory)][hashtable]$Proof)
    $Proof.pointerItems = @()
    $path = 'CopilotMonthly/pointer/current.json'
    $bootstrap = [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":2,"pointerType":"list-item-title"}')
    $reply = & $Request 'GET' "/root:/$path" $null @{}
    if ($reply.Status -eq 404) {
        $parent = & $Request 'GET' '/root:/CopilotMonthly' $null @{}
        if ($parent.Status -ne 200) { throw 'Create immutable publication root before initializing pointer.' }
        $body = [Text.Encoding]::UTF8.GetBytes('{"name":"pointer","folder":{},"@microsoft.graph.conflictBehavior":"fail"}')
        $folder = @{path='CopilotMonthly/pointer';state='creating'}
        $Proof.pointerItems += @($folder)
        $create = & $Request 'POST' '/root:/CopilotMonthly:/children' $body @{}
        if ($create.Status -ne 201) { throw "Pointer initializer lost ownership or has incomplete state: HTTP $($create.Status); no overwrite." }
        $created = [Text.Encoding]::UTF8.GetString($create.Bytes) | ConvertFrom-Json
        if (-not $created.id -or $created.name -cne 'pointer') { throw 'Pointer folder metadata mismatch.' }
        $folder.itemId = $created.id
        $folder.state = 'created'
        $driveItemId = New-CopilotPointerFile -Request $Request -Path $path -Bytes $bootstrap -Proof $Proof
    } elseif ($reply.Status -eq 200) {
        $item = [Text.Encoding]::UTF8.GetString($reply.Bytes) | ConvertFrom-Json -AsHashtable
        if (-not $item.id -or -not $item.ContainsKey('file')) { throw 'Existing pointer path is not a file.' }
        $driveItemId = $item.id
        $read = & $Request 'GET' "/root:/$path`:/content" $null @{}
        if ($read.Status -ne 200 -or [Text.Encoding]::UTF8.GetString($read.Bytes) -cne [Text.Encoding]::UTF8.GetString($bootstrap)) {
            throw 'Existing pointer bootstrap differs; do not overwrite.'
        }
    } else { throw "Pointer absence unconfirmed: HTTP $($reply.Status)." }
    if ($driveItemId -notmatch '^[A-Za-z0-9_-]+$') { throw 'Pointer drive item ID rejected.' }
    $itemReply = & $Request 'GET' "/items/$driveItemId/listItem" $null @{}
    if ($itemReply.Status -ne 200) { throw 'Pointer library item identity unavailable.' }
    $listItem = [Text.Encoding]::UTF8.GetString($itemReply.Bytes) | ConvertFrom-Json
    $state = Read-CopilotPointerItem -Request $Request -ItemId $listItem.id
    $Proof.pointer = @{ driveItemId=$driveItemId; itemId=$state.itemId; previousETag=$state.eTag; previousTitle=$state.title; path=$path }
    return $state
}

function Set-CopilotCurrentPointer {
    param(
        [Parameter(Mandatory)][scriptblock]$Request,
        [Parameter(Mandatory)][hashtable]$Before,
        [Parameter(Mandatory)][ValidatePattern('^(?:repo-[1-9][0-9]*-)?[1-9][0-9]*-[1-9][0-9]*$')][string]$RunKey,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$PayloadSha256,
        [Parameter(Mandatory)][hashtable]$Proof
    )
    if ($Before.itemId -notmatch '^[1-9][0-9]*$' -or $Before.eTag -isnot [string] -or
        [string]::IsNullOrWhiteSpace($Before.eTag) -or $Before.eTag -match '[\r\n]') { throw 'Captured pointer identity or ETag is invalid.' }
    if (-not $Proof.complete -or @($Proof.files | Where-Object { -not $_.readbackVerified }).Count) {
        throw 'Current cannot advance before every publication file is verified.'
    }
    $Proof.complete = $false
    $utf8 = [Text.UTF8Encoding]::new($false)
    $driveItemId = New-CopilotPointerFile -Request $Request -Path "CopilotMonthly/$RunKey/metadata-probe.json" -Bytes $utf8.GetBytes('{"probe":"metadata-etag"}') -Proof $Proof
    $probeReply = & $Request 'GET' "/items/$driveItemId/listItem" $null @{}
    if ($probeReply.Status -ne 200) { throw 'Probe library item identity unavailable.' }
    $probeItem = $utf8.GetString($probeReply.Bytes) | ConvertFrom-Json
    $probe = Read-CopilotPointerItem -Request $Request -ItemId $probeItem.id
    $fieldsPath = "/list/items/$($probe.itemId)/fields"
    $Proof.metadataProbe = @{itemId=$probe.itemId; initialETag=$probe.eTag; statuses=@()}
    $rejected = & $Request 'PATCH' $fieldsPath $utf8.GetBytes('{"Title":"must-not-write"}') @{'If-Match'='"nonexistent-poc-etag"'}
    $Proof.metadataProbe.statuses += @($rejected.Status)
    if ($rejected.Status -ne 412) { throw 'Metadata stale ETag was not rejected; current untouched.' }
    $unchanged = Read-CopilotPointerItem -Request $Request -ItemId $probe.itemId
    if ($unchanged.title -cne $probe.title -or $unchanged.eTag -cne $probe.eTag) { throw 'Rejected probe modified state.' }
    $accepted = & $Request 'PATCH' $fieldsPath $utf8.GetBytes('{"Title":"verified-winner"}') @{'If-Match'=$probe.eTag}
    $Proof.metadataProbe.statuses += @($accepted.Status)
    if ($accepted.Status -ne 200) { throw 'Valid ETag metadata update failed; current untouched.' }
    $winner = Read-CopilotPointerItem -Request $Request -ItemId $probe.itemId
    if ($winner.title -cne 'verified-winner' -or $winner.eTag -ceq $probe.eTag) { throw 'Valid metadata readback did not advance ETag.' }
    $lost = & $Request 'PATCH' $fieldsPath $utf8.GetBytes('{"Title":"stale-loser"}') @{'If-Match'=$probe.eTag}
    $Proof.metadataProbe.statuses += @($lost.Status)
    if ($lost.Status -ne 412) { throw 'Concurrent stale writer was not rejected; current untouched.' }
    $afterProbe = Read-CopilotPointerItem -Request $Request -ItemId $probe.itemId
    if ($afterProbe.title -cne $winner.title -or $afterProbe.eTag -cne $winner.eTag) { throw 'Stale writer changed winner.' }
    $Proof.metadataProbe.verified = $true
    $manifest = @{schemaVersion=1;dataPath="Shared Documents/CopilotMonthly/$RunKey/monthly.json";sha256=$PayloadSha256}
    $title = $manifest | ConvertTo-Json -Compress
    if ($title.Length -gt 255) { throw 'Current manifest exceeds Title column contract.' }
    $Proof.currentAttempted = $true
    $updated = & $Request 'PATCH' "/list/items/$($Before.itemId)/fields" $utf8.GetBytes((@{Title=$title} | ConvertTo-Json -Compress)) @{'If-Match'=$Before.eTag}
    $Proof.currentUpdateStatus = $updated.Status
    if ($updated.Status -ne 200) { throw "Current metadata CAS failed: HTTP $($updated.Status); preserve winner, never retry." }
    $after = Read-CopilotPointerItem -Request $Request -ItemId $Before.itemId
    if ($after.title -cne $title -or $after.eTag -ceq $Before.eTag) { throw 'Current metadata readback differs; reconcile before replay.' }
    $Proof.pointer.currentETag = $after.eTag
    $Proof.pointer.currentManifest = $manifest
    $Proof.currentCommitted = $true
    $Proof.scope = 'immutable-and-metadata-current'
    $Proof.complete = $true
}

Export-ModuleMember -Function Read-CopilotPointerItem, Initialize-CopilotCurrentPointer, Set-CopilotCurrentPointer
