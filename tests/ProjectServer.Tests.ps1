BeforeAll {
    Import-Module "$PSScriptRoot/../Plectron/Plectron.psd1" -Force
    Import-Module "$PSScriptRoot/../Plectron/Private/Plectron.Core.psm1" -Force
    # -Path pointing at a folder with plectron.psd1 loads that config.
    $script:server = Start-Plectron -Path (Join-Path $PSScriptRoot 'fixtures/project') -HistoryPath (Join-Path $TestDrive 'runs') -NoBrowser -PassThru
    . "$PSScriptRoot/TestHttp.ps1"
}

AfterAll {
    Stop-Plectron -Server $server
    $client.Dispose()
}

Describe 'project server' {
    It 'exposes branding' {
        $info = (Send GET '/api/info').Json
        $info.title | Should -Be 'Fixture Ops'
        $info.accent | Should -Be '#ff0066'
        $info.logo | Should -BeTrue
    }
    It 'serves the project logo' {
        $r = Send GET '/api/logo'
        $r.Status | Should -Be 200
        $r.Response.Content.Headers.ContentType.MediaType | Should -Be 'image/svg+xml'
    }
    It 'lists module commands next to scripts without internal paths' {
        $tools = (Send GET '/api/tools').Json
        $tools.id | Should -Contain 'fixturetools.get-widget'
        $tools.id | Should -Contain 'basic'
        $tools | Where-Object { $_.ContainsKey('path') } | Should -BeNullOrEmpty
    }
    It 'runs a module command over HTTP' {
        $id = (Send POST '/api/runs' @{ toolId = 'fixturetools.invoke-echo'; parameters = @{ Text = 'via http' } }).Json.id
        $sse = Read-Sse $id
        ($sse.Events | Where-Object t -eq 'output').data | Should -Contain 'via http'
        $sse.Events[-1].data.status | Should -Be 'succeeded'
    }
    It 'refuses excluded commands' {
        (Send POST '/api/runs' @{ toolId = 'fixturetools.invoke-fail'; parameters = @{} }).Status | Should -Be 404
    }
}

Describe 'Show-Plectron' {
    It 'serves a single command and points the URL at it' {
        $s = Get-Command Get-Inline -Module FixtureTools -ErrorAction SilentlyContinue
        if (-not $s) { Import-Module (Join-Path $PSScriptRoot 'fixtures/module/FixtureTools/FixtureTools.psd1') -Force }
        $single = Get-Command Get-Inline | Show-Plectron -HistoryPath (Join-Path $TestDrive 'single') -NoBrowser -PassThru
        try {
            $single.Url | Should -Match '#/tool/fixturetools\.get-inline$'
            @(Get-PlxCatalog -State $single.State).Count | Should -Be 1
        } finally { Stop-Plectron -Server $single }
    }
    It 'refuses commands that do not come from a module' {
        function Local-Thing { 'x' }
        { Get-Command Local-Thing | Show-Plectron -NoBrowser -PassThru } | Should -Throw '*module*'
    }
}
