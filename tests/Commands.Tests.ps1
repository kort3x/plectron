BeforeAll {
    Import-Module "$PSScriptRoot/../Plectron/Private/Plectron.Core.psm1" -Force
    $script:modulePath = Join-Path $PSScriptRoot 'fixtures/module/FixtureTools/FixtureTools.psd1'
    $script:projectDir = Join-Path $PSScriptRoot 'fixtures/project'
    Import-Module $modulePath -Force
    function P($tool, $name) { $tool.parameters | Where-Object { $_.name -eq $name } }
}
AfterAll { Remove-Module FixtureTools -ErrorAction SilentlyContinue }

Describe 'ConvertTo-PlxCommandTool (functions)' {
    BeforeAll { $script:t = ConvertTo-PlxCommandTool -Command (Get-Command Get-Widget) -ModuleId 'fixturetools' }

    It 'builds an id, kind and command name' {
        $t.id | Should -Be 'fixturetools.get-widget'
        $t.kind | Should -Be 'command'
        $t.command | Should -Be 'Get-Widget'
        $t.module | Should -Be 'FixtureTools'
    }
    It 'reads help, category from .COMPONENT and examples' {
        $t.synopsis | Should -Be 'Lists widgets.'
        $t.category | Should -Be 'Inventory'
        $t.examples[0] | Should -Match 'Get-Widget -Name a'
        (P $t 'Name').help | Should -Be 'Widget name.'
    }
    It 'maps parameters like scripts, including sets and defaults' {
        $t.parameterSets | Should -Be @('ByName', 'ById')
        (P $t 'Size').widget | Should -Be 'select'
        (P $t 'Size').default | Should -Be 'Small'
        (P $t 'Id').mandatoryIn | Should -Be @('ById')
    }
    It 'prefers the table view when [OutputType] names an object type' { $t.output | Should -Be 'table' }
    It 'hides commands whose .ROLE is Hidden' {
        (ConvertTo-PlxCommandTool -Command (Get-Command Remove-Internal) -ModuleId 'x').hidden | Should -BeTrue
    }
    It 'supports inline parameter syntax' {
        $i = ConvertTo-PlxCommandTool -Command (Get-Command Get-Inline) -ModuleId 'x'
        (P $i 'Name').default | Should -Be 'inline'
    }
}

Describe 'ConvertTo-PlxCommandTool (compiled cmdlets)' {
    BeforeAll { $script:t = ConvertTo-PlxCommandTool -Command (Get-Command Get-ChildItem) -ModuleId 'mgmt' }
    It 'maps parameter metadata' {
        (P $t 'Force').widget | Should -Be 'toggle'
        (P $t 'Path').widget | Should -Be 'list'
        (P $t 'Depth').widget | Should -Be 'number'
    }
    It 'drops common parameters' {
        $t.parameters.name | Should -Not -Contain 'Verbose'
        $t.parameters.name | Should -Not -Contain 'ErrorAction'
    }
    It 'records parameter sets' {
        $t.parameterSets | Should -Contain 'Items'
        $t.parameterSets | Should -Contain 'LiteralItems'
    }
}

Describe 'Read-PlxProjectConfig' {
    BeforeAll { $script:c = Read-PlxProjectConfig -Path (Join-Path $projectDir 'plectron.psd1') }
    It 'resolves paths against the config folder' {
        $c.Root | Should -Be ((Resolve-Path $projectDir).Path)
        $c.Modules[0] | Should -Be ((Resolve-Path $modulePath).Path)
        $c.Scripts[0] | Should -Be ((Resolve-Path (Join-Path $PSScriptRoot 'fixtures/tools')).Path)
        $c.Setup | Should -Match 'setup.ps1$'
        $c.Logo | Should -Match 'logo.svg$'
    }
    It 'keeps branding and defaults' {
        $c.Title | Should -Be 'Fixture Ops'
        $c.Accent | Should -Be '#ff0066'
        $c.Include | Should -Be @('*')
    }
    It 'treats bare module names as installed modules' {
        $p = New-PlxProject -Root $projectDir -Modules @('Microsoft.PowerShell.Management', './x.psd1')
        $p.Modules[0] | Should -Be 'Microsoft.PowerShell.Management'
        $p.Modules[1] | Should -Be (Join-Path $p.Root 'x.psd1')
    }
    It 'rejects unknown keys' {
        { Read-PlxProjectConfig -Path (Join-Path $PSScriptRoot 'fixtures/bad/plectron.psd1') } | Should -Throw '*Titel*'
    }
    It 'rejects unsafe accent colours' {
        { New-PlxProject -Root $projectDir -Accent 'red;}body{display:none' } | Should -Throw '*Accent*'
    }
}

Describe 'Get-PlxCatalog' {
    BeforeAll {
        $script:state = New-PlxState -Project (Read-PlxProjectConfig -Path (Join-Path $projectDir 'plectron.psd1')) -HistoryRoot (Join-Path $TestDrive 'runs')
        $script:cat = @(Get-PlxCatalog -State $state)
    }
    It 'combines module commands and scripts' {
        $cat.id | Should -Contain 'fixturetools.get-widget'
        $cat.id | Should -Contain 'basic'
    }
    It 'applies Exclude and hidden roles' {
        $cat.id | Should -Not -Contain 'fixturetools.invoke-fail'
        $cat.id | Should -Not -Contain 'broken'
        $cat.id | Should -Not -Contain 'fixturetools.remove-internal'
        $cat.id | Should -Not -Contain 'fixturetools.get-private'
    }
    It 'lets config overrides beat help keywords' {
        ($cat | Where-Object id -eq 'fixturetools.get-widget').category | Should -Be 'Overridden'
        $echo = $cat | Where-Object id -eq 'fixturetools.invoke-echo'
        $echo.title | Should -Be 'Echo!'
        $echo.category | Should -Be 'Fun'
        (P $echo 'Text').widget | Should -Be 'textarea'
    }
    It 'finds tools by id' {
        (Find-PlxCatalogTool -State $state -Id 'fixturetools.get-inline').command | Should -Be 'Get-Inline'
        Find-PlxCatalogTool -State $state -Id 'fixturetools.invoke-fail' | Should -BeNullOrEmpty
    }
    It 'reports a module that fails to load as a broken tool' {
        $s = New-PlxState -Project (New-PlxProject -Root $TestDrive -Modules @('./Missing.psd1')) -HistoryRoot (Join-Path $TestDrive 'r2')
        $broken = @(Get-PlxCatalog -State $s)
        $broken.Count | Should -Be 1
        $broken[0].parseError | Should -Not -BeNullOrEmpty
    }
}
