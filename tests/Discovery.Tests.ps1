BeforeAll {
    Import-Module "$PSScriptRoot/../Plectron/Private/Plectron.Core.psm1" -Force
    $script:root = Join-Path $PSScriptRoot 'fixtures/tools'
    function P($tool, $name) { $tool.parameters | Where-Object { $_.name -eq $name } }
}

Describe 'Get-PlxTool' {
    BeforeAll { $script:t = Get-PlxTool -Path (Join-Path $root 'Basic.ps1') -Root $root }

    It 'reads comment-based help' {
        $t.title | Should -Be 'Basic'
        $t.synopsis | Should -Be 'Basic fixture tool.'
        $t.description | Should -Be 'Exercises every widget mapping.'
        $t.examples[0] | Should -Match 'Basic.ps1 -Name World'
        (P $t 'Name').help | Should -Be 'Who to greet.'
    }
    It 'derives an id from the relative path' {
        $t.id | Should -Be 'basic'
        (Get-PlxTool -Path (Join-Path $root 'sub/Nested.ps1') -Root $root).id | Should -Be 'sub-nested'
    }
    It 'maps mandatory string to required text' {
        $p = P $t 'Name'
        $p.widget | Should -Be 'text'
        $p.mandatory | Should -BeTrue
        $p.helpMessage | Should -Be 'Name to use'
    }
    It 'maps ValidateSet to select with default' {
        $p = P $t 'Level'
        $p.widget | Should -Be 'select'
        $p.options | Should -Be @('Low', 'High')
        $p.default | Should -Be 'Low'
    }
    It 'maps ValidateSet on arrays to multiselect' {
        $p = P $t 'Letters'
        $p.widget | Should -Be 'multiselect'
        $p.options | Should -Be @('a', 'b', 'c')
    }
    It 'maps ints with ValidateRange' {
        $p = P $t 'Count'
        $p.widget | Should -Be 'number'
        $p.integer | Should -BeTrue
        $p.min | Should -Be 1
        $p.max | Should -Be 10
        $p.default | Should -Be 3
    }
    It 'maps double to non-integer number' {
        $p = P $t 'Ratio'
        $p.widget | Should -Be 'number'
        $p.integer | Should -BeFalse
    }
    It 'maps switch and bool to toggle' {
        (P $t 'Force').widget | Should -Be 'toggle'
        (P $t 'Force').type | Should -Be 'switch'
        (P $t 'Enabled').widget | Should -Be 'toggle'
        (P $t 'Enabled').default | Should -BeTrue
    }
    It 'maps arrays to list' { (P $t 'Tags').widget | Should -Be 'list' }
    It 'evaluates @() array defaults' { (P $t 'Tags').default | Should -Be @('one', 'two') }
    It 'maps datetime' { (P $t 'When').widget | Should -Be 'datetime' }
    It 'maps secrets' {
        (P $t 'Secret').widget | Should -Be 'password'
        (P $t 'Cred').widget | Should -Be 'credential'
    }
    It 'maps ValidatePattern' { (P $t 'Code').pattern | Should -Be '^\d+$' }
    It 'maps enums to select' {
        $p = P $t 'Day'
        $p.widget | Should -Be 'select'
        $p.options | Should -Contain 'Monday'
    }
    It 'treats untyped as text' { (P $t 'Untyped').widget | Should -Be 'text' }
    It 'keeps non-literal defaults as text only' {
        $p = P $t 'Computed'
        $p.default | Should -BeNullOrEmpty
        $p.defaultText | Should -Be '(Get-Date).ToString()'
    }
    It 'keeps declaration order' {
        $t.parameters[0].name | Should -Be 'Name'
        $t.parameters[1].name | Should -Be 'Level'
    }
}

Describe 'parameter sets' {
    BeforeAll { $script:t = Get-PlxTool -Path (Join-Path $root 'Sets.ps1') -Root $root }
    It 'lists sets with the default first' {
        $t.parameterSets | Should -Be @('ByName', 'ById')
        $t.defaultParameterSet | Should -Be 'ByName'
    }
    It 'records set membership and per-set mandatory' {
        (P $t 'Name').sets | Should -Be @('ByName')
        (P $t 'Name').mandatoryIn | Should -Be @('ByName')
        (P $t 'Common').sets.Count | Should -Be 0
    }
}

Describe 'sidecar overrides' {
    BeforeAll { $script:t = Get-PlxTool -Path (Join-Path $root 'WithSidecar.ps1') -Root $root }
    It 'overrides tool metadata' {
        $t.title | Should -Be 'Pretty Sidecar'
        $t.category | Should -Be 'Demo'
        $t.icon | Should -Be 'star'
        $t.description | Should -Be 'Overridden description.'
        $t.output | Should -Be 'text'
        $t.synopsis | Should -Be 'Original synopsis.'
    }
    It 'overrides parameters and reorders' {
        $t.parameters[0].name | Should -Be 'Title'
        $b = P $t 'Body'
        $b.label | Should -Be 'Message body'
        $b.widget | Should -Be 'textarea'
        $b.placeholder | Should -Be 'Type here'
    }
}

Describe 'edge cases' {
    It 'reports parse errors instead of throwing' {
        $t = Get-PlxTool -Path (Join-Path $root 'Broken.ps1') -Root $root
        $t.parseError | Should -Not -BeNullOrEmpty
    }
    It 'detects Desktop edition requirement' {
        (Get-PlxTool -Path (Join-Path $root 'Desktop.ps1') -Root $root).requiresDesktop | Should -BeTrue
        (Get-PlxTool -Path (Join-Path $root 'Basic.ps1') -Root $root).requiresDesktop | Should -BeFalse
    }
}

Describe 'Get-PlxTools' {
    BeforeAll { $script:cache = [hashtable]::Synchronized(@{}) }
    It 'finds scripts recursively and excludes hidden' {
        $ids = (Get-PlxTools -Root $root -Cache $cache).id
        $ids | Should -Contain 'basic'
        $ids | Should -Contain 'sub-nested'
        $ids | Should -Not -Contain 'hidden'
    }
    It 'finds hidden when asked' {
        (Get-PlxTools -Root $root -Cache $cache -IncludeHidden).id | Should -Contain 'hidden'
    }
    It 'caches by mtime' {
        $null = Get-PlxTools -Root $root -Cache $cache
        $cache.Count | Should -BeGreaterThan 0
    }
}
