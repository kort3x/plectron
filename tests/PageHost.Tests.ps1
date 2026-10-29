BeforeAll {
    Import-Module "$PSScriptRoot/../Plectron/Private/Plectron.Core.psm1" -Force
    $script:pageHost = Join-Path $PSScriptRoot '../Plectron/RunHost/PageHost.ps1'
    $script:exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $script:fixture = Join-Path $PSScriptRoot 'fixtures/pages/Fixture.ps1'

    function Start-TestPageHost([string]$Page) {
        $job = Join-Path $TestDrive "page-$([guid]::NewGuid()).json"
        ConvertTo-PlxJson @{ pagePath = $Page; root = (Split-Path $Page) } | Set-Content -LiteralPath $job -Encoding UTF8
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = "-NoProfile -NonInteractive -File `"$pageHost`" -JobPath `"$job`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        [pscustomobject]@{ Process = $p; Pending = $null; Handlers = @{}; Versions = @{} }
    }
    function Send-HostRequest($HostInfo, [hashtable]$Request) {
        $HostInfo.Process.StandardInput.WriteLine((ConvertTo-PlxJson $Request))
        $HostInfo.Process.StandardInput.Flush()
    }
    # Read events until a 'done' for RequestId arrives; returns all events read.
    function Read-UntilDone($HostInfo, [string]$RequestId, [int]$TimeoutSec = 30) {
        $events = New-Object System.Collections.Generic.List[object]
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (-not $HostInfo.Pending) { $HostInfo.Pending = $HostInfo.Process.StandardOutput.ReadLineAsync() }
            $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if (-not $HostInfo.Pending.Wait([Math]::Max(1, $left))) { break }
            $line = $HostInfo.Pending.Result
            $HostInfo.Pending = $null
            if ($null -eq $line) { break }
            $e = ConvertFrom-PlxEventLine $line
            if (-not $e) { continue }
            $events.Add($e)
            if ($e.t -eq 'layout') { foreach ($n in (Get-LayoutNodes $e.data)) { if ($n.handler) { $HostInfo.Handlers[$n.name] = $n.handler } } }
            if ($e.t -eq 'data') { $HostInfo.Versions[$e.data.name] = $e.data.version }
            if ($e.t -eq 'done' -and $e.req -eq $RequestId) { return $events.ToArray() }
        }
        throw "No 'done' for request '$RequestId' within $TimeoutSec s. Got: $(($events | ForEach-Object { $_.t }) -join ', ')"
    }
    function Get-LayoutNodes($Node) { $Node; foreach ($c in $Node.children) { Get-LayoutNodes $c } }
    function Invoke-Host($HostInfo, [hashtable]$Request) {
        $Request.id = [guid]::NewGuid().ToString('N').Substring(0, 8)
        Send-HostRequest $HostInfo $Request
        Read-UntilDone $HostInfo $Request.id
    }
    function Out-Lines($Events) { @($Events | Where-Object t -eq 'output' | ForEach-Object { $_.data }) }
    function Done($Events) { ($Events | Where-Object t -eq 'done').data }
}

Describe 'PageHost' {
    BeforeAll {
        $script:h = Start-TestPageHost $fixture
        $script:load = Read-UntilDone $h 'load'
    }
    AfterAll { if (-not $h.Process.HasExited) { $h.Process.Kill() } }

    It 'loads the layout and initial data' {
        (Done $load).status | Should -Be 'succeeded'
        ($load | Where-Object t -eq 'layout').data.props.title | Should -Be 'Fixture page'
        ($load | Where-Object { $_.t -eq 'data' -and $_.data.name -eq 'Items' }).data.rows.Count | Should -Be 3
        ($load | Where-Object t -eq 'warning').data | Should -Contain 'loading items'
        $load | ForEach-Object { $_.req | Should -Be 'load' }
    }
    It 'gives actions the real selected objects' {
        $ev = Invoke-Host $h @{ type = 'invoke'; handler = $h.Handlers.Inspect; inputs = @{ Pick = 'a' }; selections = @{ Items = @{ version = $h.Versions.Items; keys = @(1) } } }
        Out-Lines $ev | Should -Contain 'same:True'
        Out-Lines $ev | Should -Contain 'count:1 selected:1'
        (Done $ev).status | Should -Be 'succeeded'
    }
    It 'keeps variables between requests' {
        $null = Invoke-Host $h @{ type = 'invoke'; handler = $h.Handlers.Count }
        Out-Lines (Invoke-Host $h @{ type = 'invoke'; handler = $h.Handlers.Count }) | Should -Contain 'counter:2'
    }
    It 'reports failures and stale selections without dying' {
        $failed = Done (Invoke-Host $h @{ type = 'invoke'; handler = $h.Handlers.Fail })
        $failed.status | Should -Be 'failed'
        $failed.error | Should -Be 'action failed'
        $stale = Done (Invoke-Host $h @{ type = 'invoke'; handler = $h.Handlers.Inspect; selections = @{ Items = @{ version = 999; keys = @(0) } } })
        $stale.error | Should -Match 'changed'
        (Done (Invoke-Host $h @{ type = 'invoke'; handler = 'h999' })).error | Should -Match 'Unknown action'
    }
    It 'refreshes after an action and sends messages' {
        $ev = Invoke-Host $h @{ type = 'invoke'; handler = $h.Handlers.Remove; selections = @{ Items = @{ version = $h.Versions.Items; keys = @(0) } } }
        ($ev | Where-Object t -eq 'data').data.rows.Count | Should -Be 2
        $msg = ($ev | Where-Object t -eq 'message').data
        $msg.text | Should -Be 'Removed'
        $msg.level | Should -Be 'success'
    }
    It 'cancels a running action and stays usable' {
        $id = 'slow1'
        Send-HostRequest $h @{ id = $id; type = 'invoke'; handler = $h.Handlers.Slow }
        Start-Sleep -Seconds 2
        Send-HostRequest $h @{ type = 'cancel' }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ev = Read-UntilDone $h $id 15
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 10
        (Done $ev).status | Should -Be 'cancelled'
        ($ev | Where-Object t -eq 'progress').data.activity | Should -Contain 'Waiting'
        Out-Lines (Invoke-Host $h @{ type = 'invoke'; handler = $h.Handlers.Count }) | Should -Contain 'counter:3'
    }
    It 'exits when stdin closes' {
        $h.Process.StandardInput.Close()
        $h.Process.WaitForExit(10000) | Should -BeTrue
    }
}

Describe 'PageHost with a broken page' {
    It 'reports the error and exits' {
        $bad = Join-Path $TestDrive 'Bad.ps1'
        Set-Content $bad "New-PlxPage { New-PlxTextBox -Name A; New-PlxTextBox -Name A }"
        $h = Start-TestPageHost $bad
        $done = Done (Read-UntilDone $h 'load')
        $done.status | Should -Be 'failed'
        $done.error | Should -Match "Bad.ps1 line 1: the name 'A' is already used"
        $h.Process.WaitForExit(10000) | Should -BeTrue
    }
}
