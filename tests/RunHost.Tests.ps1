BeforeAll {
    Import-Module "$PSScriptRoot/../Plectron/Private/Plectron.Core.psm1" -Force
    $script:runHost = Join-Path $PSScriptRoot '../Plectron/RunHost/RunHost.ps1'
    $script:streams = Join-Path $PSScriptRoot 'fixtures/tools/Streams.ps1'
    $script:exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    function Invoke-RunHost([hashtable]$Parameters = @{}, [hashtable]$Secure = @{}) {
        $job = Join-Path $TestDrive "job-$([guid]::NewGuid()).json"
        ConvertTo-PlxJson @{ scriptPath = $streams; parameters = $Parameters; secure = $Secure } | Set-Content -LiteralPath $job -Encoding UTF8
        $lines = & $exe -NoProfile -NonInteractive -File $runHost -JobPath $job
        $events = foreach ($l in $lines) {
            $parsed = ConvertFrom-PlxEventLine $l
            if ($parsed) { $parsed }
        }
        [pscustomobject]@{ Events = @($events); JobExists = (Test-Path $job) }
    }
}

Describe 'RunHost' {
    BeforeAll { $script:r = Invoke-RunHost }

    It 'deletes the job file' { $r.JobExists | Should -BeFalse }
    It 'emits output primitives and objects' {
        $out = @($r.Events | Where-Object t -eq 'output')
        $out[0].data | Should -Be 'plain'
        $out[1].data.Name | Should -Be 'alpha'
        ([datetime]$out[1].data.When).ToUniversalTime() | Should -Be ([datetime]::new(2024, 1, 2, 3, 4, 5))
        $out[1].data.Nested.Inner | Should -Be 'x'
        $out[1].type | Should -Match 'PSCustomObject'
    }
    It 'emits warning, verbose, error, info and host streams' {
        ($r.Events | Where-Object t -eq 'warning').data | Should -Be 'careful'
        ($r.Events | Where-Object t -eq 'verbose').data | Should -Be 'verbose msg'
        ($r.Events | Where-Object t -eq 'error').data.message | Should -Be 'non-terminating'
        $info = @($r.Events | Where-Object t -eq 'info')
        ($info | Where-Object { -not $_.data.host }).data.message | Should -Be 'info msg'
        $hostMsg = $info | Where-Object { $_.data.host }
        $hostMsg.data.message | Should -Be 'host msg'
        $hostMsg.data.fg | Should -Be 'Green'
    }
    It 'emits progress records' {
        $p = @($r.Events | Where-Object t -eq 'progress')
        $p[0].data.activity | Should -Be 'Working'
        $p[0].data.percent | Should -Be 50
        $p[0].data.id | Should -Be 1
        $p[-1].data.completed | Should -BeTrue
    }
    It 'ends with an exit event' {
        $r.Events[-1].t | Should -Be 'exit'
        $r.Events[-1].data.status | Should -Be 'succeeded'
        $r.Events[-1].data.exitCode | Should -Be 0
    }
    It 'stamps every event with a timestamp' {
        $r.Events | ForEach-Object { $_.ts | Should -Not -BeNullOrEmpty }
    }
}

Describe 'RunHost outcomes' {
    It 'passes typed parameters' {
        $r = Invoke-RunHost @{ Text = 'hi'; ExitCode = 0 }
        ($r.Events | Where-Object t -eq 'output')[0].data | Should -Be 'hi'
    }
    It 'reports exit codes as failures' {
        $r = Invoke-RunHost @{ ExitCode = 3 }
        $r.Events[-1].data.exitCode | Should -Be 3
        $r.Events[-1].data.status | Should -Be 'failed'
    }
    It 'reports terminating errors' {
        $r = Invoke-RunHost @{ Throw = $true }
        $r.Events[-1].data.status | Should -Be 'failed'
        ($r.Events | Where-Object t -eq 'error' | Where-Object { $_.data.terminating }).data.message | Should -Be 'boom'
    }
    It 'rebuilds secure strings and credentials' {
        $r = Invoke-RunHost -Secure @{
            Secret = @{ kind = 'securestring'; password = 's3'}
            Cred   = @{ kind = 'credential'; user = 'bob'; password = 'pw' }
        }
        $out = ($r.Events | Where-Object t -eq 'output').data
        $out | Should -Contain 'secret:s3'
        $out | Should -Contain 'cred:bob:pw'
    }
    It 'reports binding errors as failure' {
        $r = Invoke-RunHost @{ NoSuchParam = 1 }
        $r.Events[-1].data.status | Should -Be 'failed'
    }
}

Describe 'ConvertFrom-PlxEventLine' {
    It 'returns null for non-protocol lines' { ConvertFrom-PlxEventLine 'hello' | Should -BeNullOrEmpty }
    It 'parses protocol lines' {
        $e = ConvertFrom-PlxEventLine ("$([char]0x1E)PLX " + '{"t":"output","data":1}')
        $e.t | Should -Be 'output'
    }
}
