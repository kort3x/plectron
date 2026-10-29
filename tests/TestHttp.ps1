# Shared HTTP helpers for server tests. Dot-source after setting $server.
Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$handler.UseCookies = $false
$script:client = New-Object System.Net.Http.HttpClient ($handler)
$script:client.Timeout = [TimeSpan]::FromSeconds(60)

function Send([string]$Method, [string]$Path, $Body, [hashtable]$Headers, [switch]$NoToken) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::new($Method), "$base$Path")
    if (-not $NoToken) { $req.Headers.Add('X-Plectron-Token', $server.Token) }
    if ($Headers) { foreach ($k in $Headers.Keys) { $req.Headers.TryAddWithoutValidation($k, $Headers[$k]) | Out-Null } }
    if ($null -ne $Body) { $req.Content = New-Object System.Net.Http.StringContent ((ConvertTo-PlxJson $Body), [Text.Encoding]::UTF8, 'application/json') }
    $res = $client.SendAsync($req).GetAwaiter().GetResult()
    $text = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $json = $null
    if ($res.Content.Headers.ContentType -and $res.Content.Headers.ContentType.MediaType -eq 'application/json' -and $text) { $json = ConvertFrom-PlxJson $text }
    [pscustomobject]@{ Status = [int]$res.StatusCode; Text = $text; Json = $json; Response = $res }
}
function Read-Sse([string]$Id) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$base/api/runs/$Id/events")
    $req.Headers.Add('X-Plectron-Token', $server.Token)
    $res = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $reader = New-Object IO.StreamReader ($res.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
    $events = New-Object System.Collections.Generic.List[object]
    while ($null -ne ($line = $reader.ReadLine())) {
        if ($line.StartsWith('data: ')) { $events.Add((ConvertFrom-PlxJson $line.Substring(6))) }
    }
    $reader.Dispose()
    [pscustomobject]@{ ContentType = $res.Content.Headers.ContentType.MediaType; Events = $events.ToArray() }
}
$script:base = "http://localhost:$($server.Port)"

# An SSE connection that stays open; read from it with Read-SseUntil.
function Open-Sse([string]$Path) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$base$Path")
    $req.Headers.Add('X-Plectron-Token', $server.Token)
    $res = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $stream = $res.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    [pscustomobject]@{ Status = [int]$res.StatusCode; Reader = (New-Object IO.StreamReader ($stream)); Pending = $null; Response = $res }
}

# Reads events until $Until returns true for one of them (or the stream ends); returns the events read.
function Read-SseUntil($Sse, [scriptblock]$Until, [int]$TimeoutSec = 30) {
    $events = New-Object System.Collections.Generic.List[object]
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not $Sse.Pending) { $Sse.Pending = $Sse.Reader.ReadLineAsync() }
        $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if (-not $Sse.Pending.Wait([Math]::Max(1, $left))) { break }
        $line = $Sse.Pending.Result
        $Sse.Pending = $null
        if ($null -eq $line) { return $events.ToArray() }
        if (-not $line.StartsWith('data: ')) { continue }
        $e = ConvertFrom-PlxJson $line.Substring(6)
        $events.Add($e)
        if (& $Until $e) { return $events.ToArray() }
    }
    throw "Timed out after $TimeoutSec s. Got: $(($events | ForEach-Object { $_.t }) -join ', ')"
}

function Close-Sse($Sse) { $Sse.Reader.Dispose(); $Sse.Response.Dispose() }
