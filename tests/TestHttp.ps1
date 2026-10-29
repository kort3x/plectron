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
