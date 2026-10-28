#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$PublisherClientId,
    [Parameter(Mandatory)][string]$SiteId,
    [Parameter(Mandatory)][guid]$LibraryId,
    [Parameter(Mandatory)][string]$SummaryPath,
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$DepartmentReports,
    [string]$UsersPath,
    [string]$UsagePath,
    [switch]$Apply
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($SiteId -notmatch '^[a-z0-9-]+\.sharepoint\.com,[0-9a-f-]{36},[0-9a-f-]{36}$'){throw 'Invalid composite site ID'}
if($env:GITHUB_REPOSITORY -cne 'aktsmm/m365-copilot-insights' -or
    $env:GITHUB_REPOSITORY_ID -notmatch '^[1-9][0-9]*$' -or $env:GITHUB_RUN_ID -notmatch '^[0-9]+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^[0-9]+$'){throw 'Owned Actions run context required'}
if(-not $env:RUNNER_TEMP -or (Test-Path -LiteralPath $OutputPath)){throw 'Runner storage required and output must not exist'}
$validation=Join-Path $env:RUNNER_TEMP $(if($DepartmentReports){'copilot-department-validated'}else{'copilot-publish-validated'})
if(Test-Path -LiteralPath $validation){throw 'Validation directory exists; preserve for inspection'}
$url="https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
$proof=@{observedAt=[DateTime]::UtcNow.ToString('o');runUrl=$url;applicationAuthenticationVerified=$false;files=@();ungrantedRootDenied=$false;selectedSiteReadStatus=$null;complete=$false;mode=$(if($Apply){'apply'}else{'dry-run'})}
try {
    if($DepartmentReports){
        if(-not $UsersPath -or -not $UsagePath){throw 'Department publication requires original directory and usage inputs'}
        & (Join-Path $PSScriptRoot 'Build-CopilotDashboard.ps1') -UsersPath $UsersPath -UsagePath $UsagePath -OutputDirectory $validation -DataClass tenant | Out-Null
        $manifest=Get-Content (Join-Path $validation 'manifest.json') -Raw -Encoding utf8|ConvertFrom-Json
        if(-not $manifest.distributionAllowed -or -not $manifest.reconciliationPassed -or $manifest.quarantinedRows -ne 0){throw 'Department distribution is blocked'}
        $verifiedNames=@($manifest.files.path)+@('manifest.json')
        $publishFiles=@($manifest.files.path|Where-Object {$_ -eq 'index.html' -or $_ -match '^dept-[a-f0-9]+/(usage\.csv|index\.html)$'})
        if($publishFiles.Count -lt 3){throw 'No complete department reports'}
    }else{
        & (Join-Path $PSScriptRoot 'Export-CopilotSourceObservation.ps1') -SummaryPath $SummaryPath -OutputDirectory $validation -RunUrl $url | Out-Null
        $verifiedNames=@('source-observation.csv','source-observation.json','index.html')
        $publishFiles=@('source-observation.csv','index.html')
    }
    foreach($name in $verifiedNames){
        $source=Join-Path $SourceDirectory $name
        if(-not(Test-Path -LiteralPath $source -PathType Leaf) -or
            (Get-FileHash -LiteralPath $source).Hash -cne (Get-FileHash -LiteralPath (Join-Path $validation $name)).Hash){throw 'Source differs from allowlisted deterministic regeneration'}
    }
    if ($env:SPO_SITE_PATH -cnotmatch '^/sites/[A-Za-z0-9-]+$' -or
    $env:SPO_OWNERSHIP_MARKER -cnotmatch '^[A-Za-z0-9-]{8,100}$') { throw 'Explicit site path and ownership marker required' }
    Import-Module (Join-Path $PSScriptRoot 'Copilot.Graph.psm1') -Force
    $token=Get-CopilotOidcToken -TenantId $TenantId -ClientId $PublisherClientId -ExpectedRoles @('Sites.Selected')
    $proof.applicationAuthenticationVerified=$true
    $root=Invoke-CopilotGraph -Uri 'https://graph.microsoft.com/v1.0/sites/root?$select=id' -Token $token -AllowError
    if($root.Status -ne 403){throw 'Unselected root is not denied; stop publishing'}
    $proof.ungrantedRootDenied=$true
    $siteResponse=Invoke-CopilotGraph -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId`?`$select=id,webUrl,description" -Token $token -AllowError
    $proof.selectedSiteReadStatus=$siteResponse.Status
    if($siteResponse.Status -ne 200){throw "Selected site read failed: HTTP $($siteResponse.Status); verify explicit site grant; no upload attempted"}
    $site=$siteResponse.Text|ConvertFrom-Json
    if($site.id -ine $SiteId -or $site.description -notlike ("*"+$env:SPO_OWNERSHIP_MARKER+"*") -or
        ([uri]$site.webUrl).AbsolutePath -ne $env:SPO_SITE_PATH){throw 'Live site ownership mismatch'}
    $driveResponse=Invoke-CopilotGraph -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$LibraryId/drive" -Token $token
    $drive=$driveResponse.Text|ConvertFrom-Json
    if(([uri]$drive.webUrl).Host -ne $SiteId.Split(',')[0] -or
        [uri]::UnescapeDataString(([uri]$drive.webUrl).AbsolutePath) -ne ($env:SPO_SITE_PATH+"/Shared Documents")){throw 'Owned document library mismatch'}
    $pending=@()
    foreach($sourceName in $publishFiles){
        $suffix=$sourceName.Replace('/','-')
        $name=if($DepartmentReports){"department-repo-$env:GITHUB_REPOSITORY_ID-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT-$suffix"}else{"source-observation-repo-$env:GITHUB_REPOSITORY_ID-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT.$([IO.Path]::GetExtension($sourceName).TrimStart('.'))"}
        $endpoint="https://graph.microsoft.com/v1.0/drives/$($drive.id)/root:/$name"
        $existing=Invoke-CopilotGraph -Uri $endpoint -Token $token -AllowError
        if($existing.Status -ne 404){throw 'Destination exists or absence unconfirmed; never overwrite/replay'}
        $pending+=@{name=$name;source=(Join-Path $validation $sourceName);endpoint=$endpoint}
    }
    foreach($file in $pending){
        if(-not $Apply){continue}
        $uploaded=Invoke-CopilotGraph -Uri "$($file.endpoint):/content" -Token $token -Method PUT -InputFile $file.source
        $item=$uploaded.Text|ConvertFrom-Json
        $local=Get-Item -LiteralPath $file.source
        if($uploaded.Status -ne 201 -or $item.name -cne $file.name -or $item.size -ne $local.Length -or -not $item.id){throw 'Upload outcome requires reconciliation; never replay'}
        $entry=@{name=$item.name;itemId=$item.id;driveId=$drive.id;length=$item.size;sourceSha256=(Get-FileHash -LiteralPath $local.FullName).Hash.ToLowerInvariant();readbackVerified=$false}
        $proof.files+= $entry
        $handler=[Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect=$false
        $client=[Net.Http.HttpClient]::new($handler)
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,"https://graph.microsoft.com/v1.0/drives/$($drive.id)/items/$($item.id)/content")
        $request.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$token)
        $response=$null
        $download=$null
        try {
            $response=$client.SendAsync($request).GetAwaiter().GetResult()
            if([int]$response.StatusCode -eq 302){
                $location=$response.Headers.Location
                if($location.Scheme -ne 'https' -or $location.Host -ne $SiteId.Split(',')[0]){throw 'Unexpected download host; token will not be forwarded'}
                $download=$client.GetAsync($location).GetAwaiter().GetResult()
                if([int]$download.StatusCode -ne 200){throw 'File readback download failed'}
                $bytes=$download.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            } elseif([int]$response.StatusCode -eq 200){
                $bytes=$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            } else {throw "File readback failed: HTTP $([int]$response.StatusCode)"}
            $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            if($hash -cne $entry.sourceSha256 -or $bytes.Length -ne $entry.length){throw 'Published bytes differ from regenerated source'}
            $entry.readbackVerified=$true
            $entry.readbackSha256=$hash
        } finally {
            if($download){$download.Dispose()}
            if($response){$response.Dispose()}
            $request.Dispose()
            $client.Dispose()
        }
    }
    $proof.complete= [bool]$Apply
    Write-Output "Publisher: mode=$($proof.mode), verified files=$(@($proof.files|Where-Object readbackVerified).Count), unselected root denied"
} finally {
    [void][IO.Directory]::CreateDirectory((Split-Path $OutputPath))
    [IO.File]::WriteAllText($OutputPath,($proof|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    if(Test-Path -LiteralPath $validation){Remove-Item -LiteralPath $validation -Recurse -Force}
}
