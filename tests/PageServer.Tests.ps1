BeforeAll {
    Import-Module "$PSScriptRoot/../Plectron/Plectron.psd1" -Force
    Import-Module "$PSScriptRoot/../Plectron/Private/Plectron.Core.psm1" -Force
    $script:fixturePage = Join-Path $PSScriptRoot 'fixtures/pages/Fixture.ps1'
    $script:server = Start-Plectron -Page $fixturePage -HistoryPath (Join-Path $TestDrive 'runs') -NoBrowser -PassThru
    . "$PSScriptRoot/TestHttp.ps1"

    function Get-LayoutNodes($Node) { $Node; foreach ($c in $Node.children) { Get-LayoutNodes $c } }
    function New-Session {
        $sid = (Send POST '/api/pages/fixture/sessions' @{}).Json.id
        $sse = Open-Sse "/api/sessions/$sid/events"
        $load = Read-SseUntil $sse { param($e) $e.t -eq 'done' -and $e.req -eq 'load' }
        $handlers = @{}
        foreach ($n in (Get-LayoutNodes ($load | Where-Object t -eq 'layout').data)) { if ($n.handler) { $handlers[$n.name] = $n.handler } }
        $version = ($load | Where-Object { $_.t -eq 'data' -and $_.data.name -eq 'Items' }).data.version
        [pscustomobject]@{ Id = $sid; Sse = $sse; Load = $load; Handlers = $handlers; Version = $version }
    }
    function Wait-Request($Session, [string]$RequestId) {
        Read-SseUntil $Session.Sse { param($e) $e.t -eq 'done' -and $e.req -eq $RequestId }
    }
}

AfterAll {
    Stop-Plectron -Server $server
    $client.Dispose()
}

Describe 'pages API' {
    It 'lists pages with a title and description' {
        $pages = (Send GET '/api/pages').Json
        $pages[0].id | Should -Be 'fixture'
        $pages[0].title | Should -Be 'Fixture'
        $pages[0].description | Should -Be 'Fixture page.'
        $pages[0].ContainsKey('path') | Should -BeFalse
    }
    It 'returns 404 for unknown pages and sessions' {
        (Send POST '/api/pages/nope/sessions' @{}).Status | Should -Be 404
        (Send POST '/api/sessions/0123456789abcdef/invoke' @{ handler = 'h1' }).Status | Should -Be 404
        (Send GET '/api/sessions/0123456789abcdef/events').Status | Should -Be 404
    }
    It 'reports single-page mode only when asked' {
        (Send GET '/api/info').Json.single | Should -BeFalse
    }
}

Describe 'page sessions' {
    BeforeAll { $script:s = New-Session }
    AfterAll { Close-Sse $s.Sse; $null = Send DELETE "/api/sessions/$($s.Id)" }

    It 'streams the layout and initial data' {
        ($s.Load | Where-Object t -eq 'layout').data.props.title | Should -Be 'Fixture page'
        $s.Version | Should -Be 1
    }
    It 'runs actions with selections and inputs' {
        $r = Send POST "/api/sessions/$($s.Id)/invoke" @{ handler = $s.Handlers.Inspect; inputs = @{ Pick = 'a' }; selections = @{ Items = @{ version = $s.Version; keys = @(1) } } }
        $r.Status | Should -Be 202
        $ev = Wait-Request $s $r.Json.id
        ($ev | Where-Object t -eq 'output').data | Should -Contain 'same:True'
        ($ev | Where-Object t -eq 'done').data.status | Should -Be 'succeeded'
    }
    It 'refreshes data on request' {
        $r = Send POST "/api/sessions/$($s.Id)/refresh" @{ names = @('Items'); inputs = @{ Filter = '3' } }
        $ev = Wait-Request $s $r.Json.id
        ($ev | Where-Object t -eq 'data').data.rows.value.Name | Should -Be @('item3')
    }
    It 'cancels a running action' {
        $r = Send POST "/api/sessions/$($s.Id)/invoke" @{ handler = $s.Handlers.Slow }
        Start-Sleep -Seconds 2
        (Send POST "/api/sessions/$($s.Id)/cancel" @{}).Status | Should -Be 202
        ($ev = Wait-Request $s $r.Json.id) | Out-Null
        ($ev | Where-Object t -eq 'done').data.status | Should -Be 'cancelled'
    }
    It 'rejects malformed requests' {
        (Send POST "/api/sessions/$($s.Id)/invoke" @{ handler = '../x' }).Status | Should -Be 400
        (Send POST "/api/sessions/$($s.Id)/refresh" @{ names = 'Items' }).Status | Should -Be 400
    }
}

Describe 'session lifecycle' {
    It 'deletes a session and kills its process' {
        $x = New-Session
        $entry = $server.State.Sessions[$x.Id]
        (Send DELETE "/api/sessions/$($x.Id)").Status | Should -Be 204
        $entry.Process.WaitForExit(10000) | Should -BeTrue
        $tail = @(Read-SseUntil $x.Sse { param($e) $e.t -eq 'end' } 15)
        $tail[-1].t | Should -Be 'end'
        Close-Sse $x.Sse
        (Send POST "/api/sessions/$($x.Id)/invoke" @{ handler = 'h1' }).Status | Should -Be 404
    }
    It 'reaps sessions nobody is watching' {
        $server.State.SessionIdleSeconds = 1
        try {
            $sid = (Send POST '/api/pages/fixture/sessions' @{}).Json.id
            $entry = $server.State.Sessions[$sid]
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            while ($server.State.Sessions.ContainsKey($sid) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
            $server.State.Sessions.ContainsKey($sid) | Should -BeFalse
            $entry.Process.WaitForExit(10000) | Should -BeTrue
        } finally { $server.State.SessionIdleSeconds = 120 }
    }
    It 'stops page processes with the server' {
        $other = Start-Plectron -Page $fixturePage -HistoryPath (Join-Path $TestDrive 'other') -NoBrowser -PassThru
        $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post, "http://localhost:$($other.Port)/api/pages/fixture/sessions")
        $req.Headers.Add('X-Plectron-Token', $other.Token)
        $req.Content = New-Object System.Net.Http.StringContent ('{}', [Text.Encoding]::UTF8, 'application/json')
        $sid = (ConvertFrom-PlxJson ($client.SendAsync($req).GetAwaiter().GetResult().Content.ReadAsStringAsync().GetAwaiter().GetResult())).id
        $proc = $other.State.Sessions[$sid].Process
        Stop-Plectron -Server $other
        $proc.WaitForExit(10000) | Should -BeTrue
    }
}

Describe 'Show-PlxPage' {
    It 'serves an ad-hoc page and points the URL at it' {
        $one = Show-PlxPage -Title 'Quick look' { New-PlxPage -Title 'Quick look' { New-PlxText 'hi' } } -HistoryPath (Join-Path $TestDrive 'adhoc') -NoBrowser -PassThru
        try {
            $one.Url | Should -Match '#/page/quick-look$'
            $one.State.Project.Single | Should -BeTrue
        } finally { Stop-Plectron -Server $one }
    }
}

Describe 'project pages' {
    It 'loads Pages from plectron.psd1 and keeps page files out of the tool list' {
        $root = Join-Path $TestDrive 'proj'
        $null = New-Item -ItemType Directory (Join-Path $root 'pages') -Force
        Copy-Item $fixturePage (Join-Path $root 'pages/Fixture.ps1')
        Set-Content (Join-Path $root 'plectron.psd1') "@{ Pages = @('./pages'); Scripts = @('.') }"
        $p = Start-Plectron -Path $root -HistoryPath (Join-Path $TestDrive 'proj-runs') -NoBrowser -PassThru
        try {
            @(Get-PlxPages -State $p.State).id | Should -Be @('fixture')
            @(Get-PlxCatalog -State $p.State).Count | Should -Be 0
        } finally { Stop-Plectron -Server $p }
    }
}
