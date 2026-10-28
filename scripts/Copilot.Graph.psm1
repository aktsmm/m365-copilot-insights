Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-CopilotOidcToken {
    param([Parameter(Mandatory)][guid]$TenantId, [Parameter(Mandatory)][guid]$ClientId, [Parameter(Mandatory)][string[]]$ExpectedRoles)
    if (-not $env:ACTIONS_ID_TOKEN_REQUEST_URL -or -not $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN) { throw 'GitHub Actions OIDC context is required; no credential fallback' }
    try {
        $assertion = Invoke-RestMethod -Uri "$env:ACTIONS_ID_TOKEN_REQUEST_URL&audience=api%3A%2F%2FAzureADTokenExchange" -Headers @{Authorization="Bearer $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN"}
        $token = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
            client_id=$ClientId.ToString();scope='https://graph.microsoft.com/.default'
            grant_type='client_credentials';client_assertion_type='urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            client_assertion=$assertion.value
        }
    } catch { throw 'OIDC authentication failed; private response details suppressed' }
    $part=$token.access_token.Split('.')[1].Replace('-','+').Replace('_','/')
    $part=$part.PadRight($part.Length+((4-$part.Length%4)%4),'=')
    $claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part))|ConvertFrom-Json
    if ($claims.tid -ne $TenantId.ToString() -or $claims.appid -ne $ClientId.ToString()) { throw 'Exchanged token identity mismatch' }
    if (@(Compare-Object @($ExpectedRoles|Sort-Object) @($claims.roles|Sort-Object)).Count) { throw 'Runtime Graph roles differ from the approved least-privilege set' }
    return $token.access_token
}
function Invoke-CopilotGraph {
    param([Parameter(Mandatory)][string]$Uri,[Parameter(Mandatory)][string]$Token,[ValidateSet('GET','PUT')][string]$Method='GET',[string]$InputFile,[switch]$AllowError)
    $parsed=[uri]$Uri
    if ($parsed.Scheme -ne 'https' -or $parsed.Host -ne 'graph.microsoft.com') { throw 'Unexpected Graph host' }
    for ($attempt=0;$attempt -lt 3;$attempt++) {
        $handler=[Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect=$false
        $client=[Net.Http.HttpClient]::new($handler)
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$Uri)
        $request.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Token)
        if($InputFile){$request.Content=[Net.Http.ByteArrayContent]::new([IO.File]::ReadAllBytes($InputFile))}
        $response=$null
        $download=$null
        try {
            $response=$client.SendAsync($request).GetAwaiter().GetResult()
            $status=[int]$response.StatusCode
            $retryHeader=$(if($response.Headers.RetryAfter){$response.Headers.RetryAfter.ToString()}else{$null})
            if($status -eq 302 -and $Method -eq 'GET'){
                $location=$response.Headers.Location
                if($location.Scheme -ne 'https' -or $location.Host -notin @('reports.office.com','reports.office365.com','reportsncu.office.com')){
                    throw 'Unapproved report redirect host'
                }
                # The signed report link is already authorized. Never forward the Graph bearer token.
                $download=$client.GetAsync($location).GetAwaiter().GetResult()
                $status=[int]$download.StatusCode
                if($status -ne 200 -and -not $AllowError){throw "Signed report download failed: HTTP $status"}
                $text=$download.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            } else {
                $text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
        } catch {
            throw 'Graph transport failed; private response details suppressed'
        } finally {
            if($download){$download.Dispose()}
            if($response){$response.Dispose()}
            $request.Dispose()
            $client.Dispose()
        }
        if ($status -in @(429,503,504) -and $attempt -lt 2) {
            $seconds=2*($attempt+1)
            if ($retryHeader) {
                $retry=$retryHeader
                $numeric=0
                if ([int]::TryParse($retry,[ref]$numeric)) { $seconds=[Math]::Max(1,$numeric) }
                else {
                    $date=[DateTimeOffset]::MinValue
                    if ([DateTimeOffset]::TryParse($retry,[ref]$date)) { $seconds=[int][Math]::Ceiling([Math]::Max(1,($date-[DateTimeOffset]::UtcNow).TotalSeconds)) }
                    else { throw 'Invalid Retry-After header' }
                }
            }
            if ($seconds -gt 120) { throw 'Retry-After exceeds this bounded run; rerun later' }
            Write-Warning "Graph HTTP $status; retry $($attempt+1) after $seconds seconds"
            Start-Sleep -Seconds $seconds
            continue
        }
        if ($status -lt 200 -or $status -ge 300) {
            $code="HTTP_$status"
            # Service-controlled codes and response bodies may contain private identifiers.
            if (-not $AllowError) { throw "Graph request failed: HTTP $status, $code; no stale data fallback" }
            Write-Warning "Observed Graph failure: HTTP $status, $code"
            return [pscustomobject]@{Status=$status;Text=$null;ErrorCode=$code}
        }
        return [pscustomobject]@{Status=$status;Text=$text;ErrorCode=$null}
    }
}
Export-ModuleMember -Function Get-CopilotOidcToken,Invoke-CopilotGraph
