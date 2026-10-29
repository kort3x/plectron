# HTTP server: a dispatcher runspace accepts connections and hands each
# request to a runspace pool, so long-lived SSE streams don't block others.

$script:PlxContentTypes = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'
    '.css' = 'text/css; charset=utf-8'; '.svg' = 'image/svg+xml'; '.json' = 'application/json'
    '.png' = 'image/png'; '.ico' = 'image/x-icon'; '.woff2' = 'font/woff2'
}

function Get-PlxFreePort {
    $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    try { return $l.LocalEndpoint.Port } finally { $l.Stop() }
}

function New-PlxToken {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Start-PlxServer {
    param([Parameter(Mandatory)][hashtable]$State)
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$($State.Port)/")
    $listener.Start()

    $iss = New-PlxSessionState -State $State
    $pool = [runspacefactory]::CreateRunspacePool($iss)
    $null = $pool.SetMinRunspaces(1)
    $null = $pool.SetMaxRunspaces(64)
    $pool.Open()

    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddCommand('Invoke-PlxDispatcher').AddParameters(@{ State = $State; Listener = $listener; Pool = $pool })
    $handle = $ps.BeginInvoke()
    return @{ Listener = $listener; Pool = $pool; Dispatcher = $ps; Handle = $handle }
}

function Invoke-PlxDispatcher {
    param([hashtable]$State, [System.Net.HttpListener]$Listener, $Pool)
    $inflight = New-Object System.Collections.Generic.List[object]
    while ($Listener.IsListening) {
        try { $ctx = $Listener.GetContext() } catch { break }
        $ps = [powershell]::Create()
        $ps.RunspacePool = $Pool
        $null = $ps.AddCommand('Invoke-PlxRequest').AddParameters(@{ Context = $ctx; State = $State })
        $inflight.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
        foreach ($item in @($inflight)) {
            if ($item.Handle.IsCompleted) {
                try { $item.PS.EndInvoke($item.Handle) } catch { $null = $_ }
                $item.PS.Dispose()
                $null = $inflight.Remove($item)
            }
        }
    }
}

function Stop-PlxServer {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Server)
    $State.Stopping = $true
    foreach ($id in @($State.Runs.Keys)) { $null = Stop-PlxRun -State $State -Id $id }
    try { $Server.Listener.Stop(); $Server.Listener.Close() } catch { $null = $_ }
    try { $null = $Server.Handle.AsyncWaitHandle.WaitOne(5000); $Server.Dispatcher.Dispose() } catch { $null = $_ }
    try { $Server.Pool.Close(); $Server.Pool.Dispose() } catch { $null = $_ }
    Clear-PlxFinishedRuns -State $State
}

function Send-PlxResponse {
    param($Response, [int]$Status = 200, [string]$Body = '', [string]$ContentType = 'text/plain; charset=utf-8')
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Response.ContentLength64 = $bytes.Length
    if ($bytes.Length -gt 0) { $Response.OutputStream.Write($bytes, 0, $bytes.Length) }
}

function Send-PlxJson {
    param($Response, [AllowNull()]$Data, [int]$Status = 200)
    Send-PlxResponse -Response $Response -Status $Status -Body (ConvertTo-PlxJson $Data) -ContentType 'application/json; charset=utf-8'
}

function Send-PlxError {
    param($Response, [int]$Status, [string]$Message)
    Send-PlxJson -Response $Response -Status $Status -Data @{ error = $Message }
}

# Returns $null when the request may proceed, otherwise an HTTP status to reject with.
function Test-PlxRequestAuth {
    param($Request, [hashtable]$State)
    if (-not (Test-PlxLocalHost -Request $Request -State $State)) { return 403 }
    $origin = $Request.Headers['Origin']
    if ($origin -and @(Get-PlxAllowedHosts -State $State | ForEach-Object { "http://$_" }) -notcontains $origin) { return 403 }

    $token = $Request.Headers['X-Plectron-Token']
    if (-not $token) {
        $cookie = $Request.Cookies['plx']
        if ($cookie) { $token = $cookie.Value }
    }
    if (-not (Test-PlxToken -Candidate $token -State $State)) { return 401 }
    return $null
}

# Host headers we answer to. http.sys on Windows only routes 'localhost' to the
# prefix; the loopback literals matter for the managed listener on macOS/Linux.
function Get-PlxAllowedHosts {
    param([hashtable]$State)
    return @("localhost:$($State.Port)", "127.0.0.1:$($State.Port)", "[::1]:$($State.Port)")
}

function Test-PlxLocalHost {
    param($Request, [hashtable]$State)
    return (Get-PlxAllowedHosts -State $State) -contains $Request.Headers['Host']
}

# Ordinal, constant-time comparison (PowerShell's -eq is case-insensitive).
function Test-PlxToken {
    param([AllowNull()][string]$Candidate, [hashtable]$State)
    $expected = [string]$State.Token
    if (-not $Candidate -or $Candidate.Length -ne $expected.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $expected.Length; $i++) { $diff = $diff -bor ([int]$Candidate[$i] -bxor [int]$expected[$i]) }
    return $diff -eq 0
}

function ConvertTo-PlxPublicTool {
    param($Tool, [switch]$Summary)
    $t = [ordered]@{}
    foreach ($k in $Tool.Keys) { if ($k -ne 'path') { $t[$k] = $Tool[$k] } }
    if ($Summary) { $t.Remove('parameters'); $t.Remove('examples'); $t.Remove('description') }
    return $t
}

function Read-PlxRequestJson {
    param($Request)
    if ($Request.ContentLength64 -gt 1MB) { throw 'Request body too large.' }
    $reader = New-Object IO.StreamReader ($Request.InputStream, [Text.Encoding]::UTF8)
    try { return ConvertFrom-PlxJson $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Invoke-PlxRequest {
    param($Context, [hashtable]$State)
    $req = $Context.Request
    $res = $Context.Response
    try {
        $res.Headers['X-Content-Type-Options'] = 'nosniff'
        $res.Headers['Referrer-Policy'] = 'no-referrer'
        $path = $req.Url.AbsolutePath
        $method = $req.HttpMethod

        # First visit: exchange the token from the printed URL for a cookie.
        $queryToken = $req.QueryString['t']
        if ($method -eq 'GET' -and $path -eq '/' -and (Test-PlxToken -Candidate $queryToken -State $State) -and
            (Test-PlxLocalHost -Request $req -State $State)) {
            $res.Headers.Add('Set-Cookie', "plx=$($State.Token); Path=/; HttpOnly; SameSite=Strict")
            $res.Redirect('/')
            return
        }

        $denied = Test-PlxRequestAuth -Request $req -State $State
        if ($denied) {
            $msg = 'Forbidden.'
            if ($denied -eq 401) { $msg = 'Not authorised. Open the link printed by Start-Plectron.' }
            Send-PlxResponse -Response $res -Status $denied -Body $msg
            return
        }

        if ($path.StartsWith('/api/')) { Invoke-PlxApi -Request $req -Response $res -State $State -Method $method -Path $path }
        else { Send-PlxStatic -Response $res -State $State -Path $path }
    } catch {
        try { Send-PlxError -Response $res -Status 500 -Message $_.Exception.Message } catch { $null = $_ }
    } finally {
        try { $res.Close() } catch { $null = $_ }
    }
}

function Invoke-PlxApi {
    param($Request, $Response, [hashtable]$State, [string]$Method, [string]$Path)
    $parts = @($Path.Substring(5).Split('/') | ForEach-Object { [Uri]::UnescapeDataString($_) })
    $resource = $parts[0]
    $id = $null
    if ($parts.Count -gt 1) { $id = $parts[1] }

    if ($resource -eq 'info' -and $Method -eq 'GET') {
        $manifest = Join-Path (Split-Path $State.CorePath -Parent | Split-Path) 'Plectron.psd1'
        $version = (Import-PowerShellDataFile -LiteralPath $manifest).ModuleVersion
        $engine = $null
        try { $engine = Resolve-PlxEngine -Preferred $State.Engine } catch { $engine = $null }
        Send-PlxJson $Response @{ version = $version; engine = $engine; root = $State.Root; platform = [Environment]::OSVersion.Platform.ToString() }
        return
    }

    if ($resource -eq 'tools' -and $Method -eq 'GET') {
        if (-not $id) {
            $tools = @(Get-PlxTools -Root $State.Root -Cache $State.ToolCache | ForEach-Object { ConvertTo-PlxPublicTool $_ -Summary })
            Send-PlxJson $Response $tools
            return
        }
        $tool = Find-PlxTool -Root $State.Root -Cache $State.ToolCache -Id $id
        if (-not $tool) { Send-PlxError $Response 404 "Tool '$id' not found."; return }
        Send-PlxJson $Response (ConvertTo-PlxPublicTool $tool)
        return
    }

    if ($resource -eq 'runs') {
        if (-not $id) {
            if ($Method -eq 'GET') {
                $limit = 100
                $requested = 0
                if ([int]::TryParse([string]$Request.QueryString['limit'], [ref]$requested) -and $requested -gt 0) { $limit = $requested }
                $runs = @(Get-PlxRuns -HistoryRoot $State.HistoryRoot -Limit $limit | ForEach-Object { Repair-PlxRunStatus -State $State -Meta $_ })
                Send-PlxJson $Response $runs
                return
            }
            if ($Method -eq 'POST') {
                $body = Read-PlxRequestJson $Request
                $tool = $null
                if ($body -and $body.toolId) { $tool = Find-PlxTool -Root $State.Root -Cache $State.ToolCache -Id ([string]$body.toolId) }
                if (-not $tool) { Send-PlxError $Response 404 'Tool not found.'; return }
                try { $meta = Start-PlxRun -State $State -Tool $tool -Values $body.parameters }
                catch { Send-PlxError $Response 400 $_.Exception.Message; return }
                Send-PlxJson $Response $meta 201
                return
            }
        }
        if (-not (Test-PlxRunId $id)) { Send-PlxError $Response 404 'Run not found.'; return }
        $meta = Get-PlxRun -State $State -Id $id
        if (-not $meta) { Send-PlxError $Response 404 'Run not found.'; return }

        if ($parts.Count -eq 3 -and $parts[2] -eq 'events' -and $Method -eq 'GET') {
            Send-PlxEventStream -Request $Request -Response $Response -State $State -Id $id
            return
        }
        if ($parts.Count -eq 2 -and $Method -eq 'GET') { Send-PlxJson $Response $meta; return }
        if ($parts.Count -eq 2 -and $Method -eq 'DELETE') {
            if (Stop-PlxRun -State $State -Id $id) { Send-PlxJson $Response @{ cancelled = $true } 202; return }
            Remove-PlxRun -HistoryRoot $State.HistoryRoot -Id $id
            $State.Runs.Remove($id)
            Send-PlxResponse -Response $Response -Status 204
            return
        }
    }
    Send-PlxError $Response 404 'Not found.'
}

# Server-Sent Events: replay the run's events file, then follow it until the
# 'end' event. The id field is the byte offset, so reconnects resume exactly.
function Send-PlxEventStream {
    param($Request, $Response, [hashtable]$State, [string]$Id)
    $file = Join-Path (Get-PlxRunDir -HistoryRoot $State.HistoryRoot -Id $Id) 'events.ndjson'
    [long]$offset = 0
    $resume = $Request.Headers['Last-Event-ID']
    if (-not $resume) { $resume = $Request.QueryString['from'] }
    if ($resume) { [long]::TryParse($resume, [ref]$offset) | Out-Null }

    $Response.StatusCode = 200
    $Response.ContentType = 'text/event-stream; charset=utf-8'
    $Response.Headers['Cache-Control'] = 'no-cache'
    $Response.SendChunked = $true
    $out = $Response.OutputStream
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $lastWrite = [DateTime]::UtcNow
    $finishedSeen = $false

    while (-not $State.Stopping) {
        $chunk = Read-PlxEventChunk -Path $file -Offset $offset
        if ($chunk.Lines.Count -gt 0) {
            $sb = New-Object System.Text.StringBuilder
            $ended = $false
            for ($i = 0; $i -lt $chunk.Lines.Count; $i++) {
                $line = $chunk.Lines[$i]
                if ($i -eq $chunk.Lines.Count - 1) { $null = $sb.Append("id: $($chunk.Offset)`n") }
                $null = $sb.Append("data: $line`n`n")
                if ($line.StartsWith('{"t":"end"')) { $ended = $true }
            }
            $bytes = $utf8.GetBytes($sb.ToString())
            $out.Write($bytes, 0, $bytes.Length)
            $out.Flush()
            $offset = $chunk.Offset
            $lastWrite = [DateTime]::UtcNow
            if ($ended) { break }
            continue
        }
        $entry = $State.Runs[$Id]
        if (-not $entry -or $entry.Done) {
            # One more read after the run finished, then stop (covers runs
            # from a crashed host whose file never got an 'end' event).
            if ($finishedSeen) { break }
            $finishedSeen = $true
            continue
        }
        if (([DateTime]::UtcNow - $lastWrite).TotalSeconds -ge 15) {
            $ping = $utf8.GetBytes(": ping`n`n")
            $out.Write($ping, 0, $ping.Length)
            $out.Flush()
            $lastWrite = [DateTime]::UtcNow
        }
        Start-Sleep -Milliseconds 100
    }
}

function Send-PlxStatic {
    param($Response, [hashtable]$State, [string]$Path)
    $rel = [Uri]::UnescapeDataString($Path).TrimStart('/')
    if (-not $rel) { $rel = 'index.html' }
    $root = [IO.Path]::GetFullPath($State.WwwRoot)
    $full = [IO.Path]::GetFullPath((Join-Path $root $rel))
    $inside = $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    if (-not $inside -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Send-PlxResponse -Response $Response -Status 404 -Body 'Not found.'
        return
    }
    $type = $script:PlxContentTypes[[IO.Path]::GetExtension($full).ToLowerInvariant()]
    if (-not $type) { $type = 'application/octet-stream' }
    $Response.Headers['Cache-Control'] = 'no-cache'
    $Response.Headers['Content-Security-Policy'] = "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:"
    $bytes = [IO.File]::ReadAllBytes($full)
    $Response.StatusCode = 200
    $Response.ContentType = $type
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}
