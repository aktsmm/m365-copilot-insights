Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Connect-CopilotMonthlySite {
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$PublisherClientId,
        [Parameter(Mandatory)][string]$SiteId,
        [Parameter(Mandatory)][guid]$LibraryId
    )
    if ($SiteId -notmatch '^[a-z0-9-]+\.sharepoint\.com,[0-9a-f-]{36},[0-9a-f-]{36}$') { throw 'Invalid composite site ID.' }
    if ($env:GITHUB_REPOSITORY -cne 'aktsmm/m365-copilot-insights' -or
        $env:GITHUB_REPOSITORY_ID -notmatch '^[1-9][0-9]*$' -or $env:GITHUB_RUN_ID -notmatch '^[0-9]+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^[0-9]+$') { throw 'Owned Actions context required.' }
    if ($env:SPO_SITE_PATH -cnotmatch '^/sites/[A-Za-z0-9-]+$' -or
    $env:SPO_OWNERSHIP_MARKER -cnotmatch '^[A-Za-z0-9-]{8,100}$') { throw 'Explicit site path and ownership marker required' }
    Import-Module (Join-Path $PSScriptRoot 'Copilot.Graph.psm1') -Force
    $token = Get-CopilotOidcToken -TenantId $TenantId -ClientId $PublisherClientId -ExpectedRoles @('Sites.Selected')
    $root = Invoke-CopilotGraph -Uri 'https://graph.microsoft.com/v1.0/sites/root?$select=id' -Token $token -AllowError
    if ($root.Status -ne 403) { throw 'Unselected root must be denied.' }
    $site = (Invoke-CopilotGraph -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId" -Token $token).Text | ConvertFrom-Json
    if ($site.id -ine $SiteId -or $site.description -notlike ("*"+$env:SPO_OWNERSHIP_MARKER+"*") -or
        ([uri]$site.webUrl).AbsolutePath -cne $env:SPO_SITE_PATH) { throw 'Site ownership mismatch.' }
    $drive = (Invoke-CopilotGraph -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$LibraryId/drive" -Token $token).Text | ConvertFrom-Json
    $hostName = $SiteId.Split(',')[0]
    if (([uri]$drive.webUrl).Host -cne $hostName -or
        [uri]::UnescapeDataString(([uri]$drive.webUrl).AbsolutePath) -cne ($env:SPO_SITE_PATH+"/Shared Documents")) { throw 'Document library ownership mismatch.' }
    $request = {
        param($method,$path,$bytes,$headers)
        Invoke-CopilotDriveRequest -DriveId $drive.id -Token $token -DownloadHost $hostName -SiteId $SiteId -LibraryId $LibraryId -Method $method -Path $path -Bytes $bytes -Headers $headers
    }.GetNewClosure()
    return @{ Request=$request; DriveId=$drive.id }
}

function Invoke-CopilotDriveRequest {
    param(
        [Parameter(Mandatory)][string]$DriveId,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$DownloadHost,
        [string]$SiteId,
        [guid]$LibraryId,
        [Parameter(Mandatory)][ValidateSet('GET','PUT','POST','PATCH')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][byte[]]$Bytes,
        [hashtable]$Headers = @{}
    )
    if ($DriveId -notmatch '^[A-Za-z0-9!_-]+$' -or $DownloadHost -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
        $Path -notmatch '^/(root|items/|list/items/)' -or $Path.Contains('..') -or
        ($Path.Contains('?') -and $Path -notmatch '^/list/items/[1-9][0-9]*\?\$expand=fields$')) {
        throw 'Invalid bounded drive request.'
    }
    $uri = "https://graph.microsoft.com/v1.0/drives/$DriveId$Path"
    if ($Path.StartsWith('/list/')) {
        if ($SiteId -notmatch '^[a-z0-9-]+\.sharepoint\.com,[0-9a-f-]{36},[0-9a-f-]{36}$' -or
            $LibraryId -eq [guid]::Empty -or $Path -notmatch '^/list/items/[1-9][0-9]*(/fields|\?\$expand=fields)?$') {
            throw 'Invalid bounded library item request.'
        }
        $uri = "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$LibraryId/$($Path.Substring(6))"
    }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),
        $uri)
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    foreach ($key in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key]) }
    if ($null -ne $Bytes) {
        $request.Content = [Net.Http.ByteArrayContent]::new($Bytes)
        $request.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new(
            $(if ($Method -in @('POST','PATCH')) { 'application/json' } else { 'application/octet-stream' }))
    }
    $response = $null
    $download = $null
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -eq 302 -and $Method -eq 'GET') {
            $location = $response.Headers.Location
            if (-not $location.IsAbsoluteUri -or $location.Scheme -ne 'https' -or $location.Host -cne $DownloadHost) {
                throw 'Unapproved drive download redirect; bearer token is not forwarded.'
            }
            $download = $client.GetAsync($location).GetAwaiter().GetResult()
            $status = [int]$download.StatusCode
            $data = $download.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        } else {
            $data = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        }
        return @{ Status = $status; Bytes = $data }
    } finally {
        if ($download) { $download.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
    }
}

function Publish-CopilotMonthlyFiles {
    param(
        [Parameter(Mandatory)][scriptblock]$Request,
        [Parameter(Mandatory)][ValidatePattern('^(?:repo-[1-9][0-9]*-)?[1-9][0-9]*-[1-9][0-9]*$')][string]$RunKey,
        [Parameter(Mandatory)][hashtable]$Artifacts,
        [Parameter(Mandatory)][hashtable]$RawArtifacts,
        [Parameter(Mandatory)][hashtable]$Proof,
        [switch]$SwitchCurrent,
        [switch]$Apply
    )
    $utf8 = [Text.UTF8Encoding]::new($false)
    if ($SwitchCurrent) { throw 'Content PUT current switching is retired; use ETag-guarded list item metadata.' }
    function Encode-Path([string]$Value) {
        return (($Value.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
    }
    function Read-Json($Reply) {
        return ($utf8.GetString($Reply.Bytes) | ConvertFrom-Json -AsHashtable)
    }
    function Hash([byte[]]$Value) {
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Value)).ToLowerInvariant()
    }
    function Call([string]$Method, [string]$Path, [AllowNull()][byte[]]$Body, [hashtable]$Headers = @{}) {
        return (& $Request $Method $Path $Body $Headers)
    }
    function Ensure-Folder([string]$Parent, [string]$Name, [bool]$MustBeNew) {
        $path = "$Parent/$Name".TrimStart('/')
        $encoded = Encode-Path $path
        $reply = Call GET "/root:/$encoded" $null
        if ($reply.Status -eq 200) {
            if ($MustBeNew -or -not (Read-Json $reply).ContainsKey('folder')) {
                throw 'Destination already exists or is not a folder; no overwrite.'
            }
            return
        }
        if ($reply.Status -ne 404) { throw "Folder absence unconfirmed: HTTP $($reply.Status)." }
        $parentPath = if ($Parent) { "/root:/$(Encode-Path $Parent):/children" } else { '/root/children' }
        $body = $utf8.GetBytes((@{name=$Name;folder=@{};'@microsoft.graph.conflictBehavior'='fail'} | ConvertTo-Json -Compress))
        $entry = @{ path=$path; state='creating' }
        $Proof.folders += @($entry)
        $created = Call POST $parentPath $body
        if ($created.Status -ne 201) { throw "Folder create failed: HTTP $($created.Status); never replay." }
        $item = Read-Json $created
        if (-not $item.ContainsKey('folder') -or $item.name -cne $Name -or -not $item.id) { throw 'Folder create readback mismatch.' }
        $entry.itemId = $item.id
        $entry.state = 'created'
    }
    function Write-Verified([string]$Path, [byte[]]$Value, [hashtable]$Headers, [bool]$Replace) {
        $encoded = Encode-Path $Path
        $entry = @{ path=$Path; sha256=(Hash $Value); length=$Value.Length; state='uploading'; readbackVerified=$false }
        $Proof.files += @($entry)
        $reply = Call PUT "/root:/$encoded`:/content" $Value $Headers
        $entry.httpStatus = $reply.Status
        if ($reply.Status -notin $(if ($Replace) { @(200,201) } else { @(201) })) {
            throw "Conditional upload failed: HTTP $($reply.Status); no retry or current fallback."
        }
        $item = Read-Json $reply
        if (-not $item.id -or $item.name -cne $Path.Split('/')[-1] -or $item.size -ne $Value.Length) {
            throw 'Uploaded item metadata mismatch; reconcile before replay.'
        }
        $entry.itemId = $item.id
        $entry.state = 'uploaded'
        $read = Call GET "/root:/$encoded`:/content" $null
        if ($read.Status -ne 200 -or $read.Bytes.Length -ne $Value.Length -or (Hash $read.Bytes) -cne $entry.sha256) {
            throw 'Uploaded bytes failed independent readback; current must not advance.'
        }
        $entry.state = 'verified'
        $entry.readbackVerified = $true
    }
    foreach ($pair in @(@{values=$Artifacts;raw=$false}, @{values=$RawArtifacts;raw=$true})) {
        if ($pair.values.Count -eq 0) { throw 'Both derived and daily source artifacts are required.' }
        foreach ($name in $pair.values.Keys) {
            $pattern = if ($pair.raw) { '^(users\.json|usage-D28\.csv|probe-summary\.json|raw-\d{4}-\d{2}-\d{2}\.json|snapshot-\d{4}-\d{2}-\d{2}\.json)$' }
                else { '^(monthly\.json|monthly-dashboard\.html|manifest\.json|\d{4}-\d{2}-[a-z0-9-]+\.csv)$' }
            if ($name -cnotmatch $pattern -or $pair.values[$name] -isnot [byte[]] -or
                $pair.values[$name].Length -eq 0 -or $pair.values[$name].Length -gt 10MB) {
                throw 'Artifact allowlist, type or size rejected before networking.'
            }
        }
    }
    foreach ($name in @('monthly.json','manifest.json','monthly-dashboard.html')) {
        if (-not $Artifacts.ContainsKey($name)) { throw 'Missing required monthly artifact.' }
    }
    $Proof.mode = if ($Apply) { 'apply' } else { 'dry-run' }
    $Proof.files = @()
    $Proof.folders = @()
    $Proof.complete = $false
    $Proof.currentCommitted = $false
    $Proof.scope = 'immutable-only'
    if (-not $Apply) { return }
    $currentPath = '/root:/CopilotMonthly/current.json'
    $before = Call GET $currentPath $null
    $Proof.currentBeforeStatus = $before.Status
    if ($before.Status -notin @(200,404)) { throw 'Current state is not independently known.' }
    Ensure-Folder '' 'CopilotMonthly' $false
    Ensure-Folder '' 'CopilotMonthlyRaw' $false
    Ensure-Folder 'CopilotMonthly' $RunKey $true
    Ensure-Folder 'CopilotMonthlyRaw' $RunKey $true
    foreach ($pair in @(@{values=$RawArtifacts;root="CopilotMonthlyRaw/$RunKey"}, @{values=$Artifacts;root="CopilotMonthly/$RunKey"})) {
        foreach ($name in @($pair.values.Keys | Sort-Object)) {
            Write-Verified "$($pair.root)/$name" $pair.values[$name] @{'If-None-Match'='*'} $false
        }
    }
    $index = @{
        schemaVersion=1; runKey=$RunKey
        files=@($Proof.files | ForEach-Object {
            @{path=$_.path;sha256=$_.sha256;length=$_.length}
        })
    }
    Write-Verified "CopilotMonthlyRaw/$RunKey/publication-manifest.json" $utf8.GetBytes(($index | ConvertTo-Json -Depth 8 -Compress)) @{'If-None-Match'='*'} $false
    $Proof.complete = $true
}

Export-ModuleMember -Function Connect-CopilotMonthlySite, Invoke-CopilotDriveRequest, Publish-CopilotMonthlyFiles
