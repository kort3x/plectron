BeforeAll {
    Import-Module "$PSScriptRoot/../Plectron/Plectron.psd1" -Force
    Import-Module "$PSScriptRoot/../Plectron/Private/Plectron.Core.psm1" -Force
    $script:server = Start-Plectron -Path (Join-Path $PSScriptRoot 'fixtures/tools') -HistoryPath (Join-Path $TestDrive 'runs') -NoBrowser -PassThru
    . "$PSScriptRoot/TestHttp.ps1"
}

AfterAll {
    Stop-Plectron -Server $server
    $client.Dispose()
}

Describe 'auth' {
    It 'rejects requests without a token' { (Send GET '/api/tools' -NoToken).Status | Should -Be 401 }
    It 'rejects a wrong token' { (Send GET '/api/tools' -NoToken -Headers @{ 'X-Plectron-Token' = 'nope' }).Status | Should -Be 401 }
    It 'swaps the URL token for a cookie' {
        $r = Send GET "/?t=$($server.Token)" -NoToken
        $r.Status | Should -Be 302
        $cookie = @($r.Response.Headers.GetValues('Set-Cookie'))[0]
        $cookie | Should -Match "plx=$($server.Token)"
        $cookie | Should -Match 'HttpOnly'
        $cookie | Should -Match 'SameSite=Strict'
        (Send GET '/api/tools' -NoToken -Headers @{ Cookie = "plx=$($server.Token)" }).Status | Should -Be 200
    }
    It 'compares tokens case-sensitively' {
        (Send GET '/api/tools' -NoToken -Headers @{ 'X-Plectron-Token' = $server.Token.ToUpperInvariant() }).Status | Should -Be 401
    }
    It 'rejects foreign origins even with a token' {
        (Send GET '/api/tools' -Headers @{ Origin = 'http://evil.example' }).Status | Should -Be 403
    }
    It 'accepts its own origin' {
        (Send GET '/api/tools' -Headers @{ Origin = $base }).Status | Should -Be 200
    }
}

Describe 'tools API' {
    It 'lists visible tools' {
        $r = Send GET '/api/tools'
        $r.Status | Should -Be 200
        $r.Json.id | Should -Contain 'basic'
        $r.Json.id | Should -Not -Contain 'hidden'
        $r.Text | Should -Match '^\[\{'
    }
    It 'returns a tool schema' {
        $r = Send GET '/api/tools/basic'
        $r.Json.parameters[0].name | Should -Be 'Name'
        $r.Json.ContainsKey('path') | Should -BeFalse
    }
    It 'returns 404 for unknown and hidden tools' {
        (Send GET '/api/tools/nope').Status | Should -Be 404
        (Send GET '/api/tools/hidden').Status | Should -Be 404
    }
    It 'returns server info' {
        $r = Send GET '/api/info'
        $r.Json.version | Should -Not -BeNullOrEmpty
        $r.Json.engine | Should -Not -BeNullOrEmpty
    }
}

Describe 'runs API' {
    It 'starts a run and streams its events over SSE' {
        $r = Send POST '/api/runs' @{ toolId = 'streams'; parameters = @{ Text = 'from server' } }
        $r.Status | Should -Be 201
        $id = $r.Json.id
        $sse = Read-Sse $id
        $sse.ContentType | Should -Be 'text/event-stream'
        ($sse.Events | Where-Object t -eq 'output')[0].data | Should -Be 'from server'
        $sse.Events[-1].t | Should -Be 'end'
        $sse.Events[-1].data.status | Should -Be 'succeeded'

        (Send GET "/api/runs/$id").Json.status | Should -Be 'succeeded'
        $list = Send GET '/api/runs'
        $list.Json.id | Should -Contain $id
        $list.Text | Should -Match '^\[\{'
        # replay after completion
        (Read-Sse $id).Events[-1].t | Should -Be 'end'
    }
    It 'ignores a malformed limit' {
        (Send GET '/api/runs?limit=abc').Status | Should -Be 200
    }
    It 'rejects unknown parameters' {
        (Send POST '/api/runs' @{ toolId = 'streams'; parameters = @{ Bogus = 1 } }).Status | Should -Be 400
    }
    It 'refuses hidden tools' {
        (Send POST '/api/runs' @{ toolId = 'hidden'; parameters = @{} }).Status | Should -Be 404
    }
    It 'cancels a running run, then deletes it' {
        $id = (Send POST '/api/runs' @{ toolId = 'streams'; parameters = @{ Slow = $true } }).Json.id
        Start-Sleep -Seconds 2
        (Send DELETE "/api/runs/$id").Status | Should -Be 202
        (Read-Sse $id).Events[-1].data.status | Should -Be 'cancelled'
        (Send DELETE "/api/runs/$id").Status | Should -Be 204
        (Send GET "/api/runs/$id").Status | Should -Be 404
    }
    It 'returns 404 for malformed run ids' {
        (Send GET '/api/runs/..%2F..%2Fetc').Status | Should -Be 404
    }
}

Describe 'static files' {
    It 'serves the app shell' {
        $r = Send GET '/'
        $r.Status | Should -Be 200
        $r.Response.Content.Headers.ContentType.MediaType | Should -Be 'text/html'
        $r.Text | Should -Match '<title>'
    }
    It 'serves scripts with a JS content type' {
        $r = Send GET '/app.js'
        $r.Status | Should -Be 200
        $r.Response.Content.Headers.ContentType.MediaType | Should -Be 'text/javascript'
    }
    It 'blocks path traversal' {
        # http.sys on Windows rejects encoded traversal itself with 403 before Plectron sees it.
        foreach ($path in '/..%2FPrivate%2FState.ps1', '/../Private/State.ps1') {
            $r = Send GET $path
            $r.Status | Should -BeIn @(403, 404)
            $r.Text | Should -Not -Match 'function New-PlxState'
        }
    }
}
