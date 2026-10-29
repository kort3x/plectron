BeforeAll {
    Import-Module "$PSScriptRoot/../Plectron/Private/Plectron.Core.psm1" -Force
    $script:root = Join-Path $PSScriptRoot 'fixtures/tools'
    $script:cache = [hashtable]::Synchronized(@{})
    $script:streams = Find-PlxTool -Root $root -Cache $cache -Id 'streams'
    $script:basic = Find-PlxTool -Root $root -Cache $cache -Id 'basic'

    function New-State {
        New-PlxState -Root $root -HistoryRoot (Join-Path $TestDrive "runs-$([guid]::NewGuid())")
    }
    function Get-Events($state, $id) {
        Get-Content (Join-Path (Get-PlxRunDir -HistoryRoot $state.HistoryRoot -Id $id) 'events.ndjson') | ForEach-Object { ConvertFrom-PlxJson $_ }
    }
}

Describe 'ConvertTo-PlxJob' {
    It 'drops empty values and false switches but keeps false bools' {
        $j = ConvertTo-PlxJob -Tool $basic -Values @{ Name = 'x'; Level = ''; Force = $false; Enabled = $false; Tags = @() }
        $j.parameters.Keys | Sort-Object | Should -Be @('Enabled', 'Name')
        $j.parameters.Enabled | Should -BeFalse
    }
    It 'splits secrets out and redacts them' {
        $j = ConvertTo-PlxJob -Tool $basic -Values @{ Name = 'x'; Secret = 'pw'; Cred = @{ user = 'u'; password = 'p' } }
        $j.parameters.ContainsKey('Secret') | Should -BeFalse
        $j.secure.Secret.password | Should -Be 'pw'
        $j.secure.Cred.kind | Should -Be 'credential'
        $j.redacted.Secret | Should -Be '***'
        $j.redacted.Cred.user | Should -Be 'u'
        $j.redacted.Cred.password | Should -Be '***'
        $j.redacted.Name | Should -Be 'x'
    }
    It 'decides secrecy by declared type, not by widget override' {
        $tool = @{ id = 't'; parameters = @(
                @{ name = 'Masked'; type = 'string'; widget = 'password' }
                @{ name = 'Key'; type = 'securestring'; widget = 'textarea' }
            ) }
        $j = ConvertTo-PlxJob -Tool $tool -Values @{ Masked = 'm'; Key = 'k' }
        $j.parameters.Masked | Should -Be 'm'
        $j.redacted.Masked | Should -Be '***'
        $j.secure.Key.password | Should -Be 'k'
        $j.redacted.Key | Should -Be '***'
    }
    It 'rejects unknown parameters' {
        { ConvertTo-PlxJob -Tool $basic -Values @{ Bogus = 1 } } | Should -Throw '*Bogus*'
    }
}

Describe 'Resolve-PlxEngine' {
    It 'uses the preferred engine when given' {
        Resolve-PlxEngine -Preferred 'pwsh' | Should -Match 'pwsh'
    }
    It 'defaults to an existing executable' {
        Test-Path (Resolve-PlxEngine) | Should -BeTrue
    }
}

Describe 'Start-PlxRun' {
    It 'runs a tool and records events and metadata' {
        $state = New-State
        $meta = Start-PlxRun -State $state -Tool $streams -Values @{ Text = 'hello'; Secret = 'shh' }
        $meta.status | Should -Be 'running'
        $final = Wait-PlxRun -State $state -Id $meta.id -TimeoutSec 60
        $final.status | Should -Be 'succeeded'
        $final.exitCode | Should -Be 0
        $final.parameters.Secret | Should -Be '***'
        $final.durationMs | Should -BeGreaterThan 0
        $events = @(Get-Events $state $meta.id)
        ($events | Where-Object t -eq 'output')[0].data | Should -Be 'hello'
        $events | Where-Object t -eq 'output' | Where-Object { $_.data -eq 'secret:shh' } | Should -Not -BeNullOrEmpty
        $events[-1].t | Should -Be 'end'
        $events[-1].data.status | Should -Be 'succeeded'
    }
    It 'records failures with the exit code' {
        $state = New-State
        $meta = Start-PlxRun -State $state -Tool $streams -Values @{ ExitCode = 4 }
        $final = Wait-PlxRun -State $state -Id $meta.id -TimeoutSec 60
        $final.status | Should -Be 'failed'
        $final.exitCode | Should -Be 4
    }
    It 'cancels a running tool' {
        $state = New-State
        $meta = Start-PlxRun -State $state -Tool $streams -Values @{ Slow = $true }
        Start-Sleep -Seconds 2
        Stop-PlxRun -State $state -Id $meta.id
        $final = Wait-PlxRun -State $state -Id $meta.id -TimeoutSec 20
        $final.status | Should -Be 'cancelled'
        (Get-Events $state $meta.id)[-1].data.status | Should -Be 'cancelled'
    }
}

Describe 'history' {
    It 'lists runs newest first, prunes and removes' {
        $state = New-State
        $ids = foreach ($i in 1..3) {
            $m = Start-PlxRun -State $state -Tool $streams -Values @{}
            $null = Wait-PlxRun -State $state -Id $m.id -TimeoutSec 60
            $m.id
        }
        $runs = @(Get-PlxRuns -HistoryRoot $state.HistoryRoot)
        $runs.Count | Should -Be 3
        $runs[0].id | Should -Be $ids[2]
        Limit-PlxHistory -HistoryRoot $state.HistoryRoot -Keep 2
        @(Get-PlxRuns -HistoryRoot $state.HistoryRoot).Count | Should -Be 2
        Remove-PlxRun -HistoryRoot $state.HistoryRoot -Id $ids[2]
        @(Get-PlxRuns -HistoryRoot $state.HistoryRoot).id | Should -Be @($ids[1])
    }
    It 'orders by start time across month boundaries' {
        $state = New-State
        foreach ($m in @(@{ id = '20251201-100000-aaaaaa'; startedAt = '2025-12-01T10:00:00.0000000Z' },
                         @{ id = '20260115-100000-bbbbbb'; startedAt = '2026-01-15T10:00:00.0000000Z' })) {
            $dir = Join-Path $state.HistoryRoot $m.id
            $null = New-Item -ItemType Directory $dir -Force
            Save-PlxRunMeta -Dir $dir -Meta @{ id = $m.id; startedAt = $m.startedAt; status = 'succeeded' }
        }
        (Get-PlxRuns -HistoryRoot $state.HistoryRoot)[0].id | Should -Be '20260115-100000-bbbbbb'
        Limit-PlxHistory -HistoryRoot $state.HistoryRoot -Keep 1
        @(Get-PlxRuns -HistoryRoot $state.HistoryRoot).id | Should -Be @('20260115-100000-bbbbbb')
    }
    It 'rejects ids that could escape the history folder' {
        { Get-PlxRunDir -HistoryRoot $TestDrive -Id '../etc' } | Should -Throw
    }
    It 'marks runs left running by a dead host as abandoned' {
        $state = New-State
        $dir = Join-Path $state.HistoryRoot '20200101-000000-abcdef'
        $null = New-Item -ItemType Directory $dir -Force
        Save-PlxRunMeta -Dir $dir -Meta @{ id = '20200101-000000-abcdef'; status = 'running' }
        (Get-PlxRun -State $state -Id '20200101-000000-abcdef').status | Should -Be 'abandoned'
    }
}

Describe 'Read-PlxEventChunk' {
    It 'returns only complete lines and advances the offset' {
        $f = Join-Path $TestDrive 'ev.ndjson'
        [IO.File]::WriteAllText($f, "{`"a`":1}`n{`"b`":")
        $r = Read-PlxEventChunk -Path $f -Offset 0
        $r.Lines | Should -Be @('{"a":1}')
        [IO.File]::AppendAllText($f, "2}`n")
        $r2 = Read-PlxEventChunk -Path $f -Offset $r.Offset
        $r2.Lines | Should -Be @('{"b":2}')
    }
}
