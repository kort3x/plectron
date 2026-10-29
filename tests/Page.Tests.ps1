BeforeAll {
    . "$PSScriptRoot/../Plectron/Private/Compat.ps1"
    . "$PSScriptRoot/../Plectron/Private/PageModel.ps1"
    . "$PSScriptRoot/../Plectron/Public/Page.ps1"
    $script:fixture = Join-Path $PSScriptRoot 'fixtures/pages/Fixture.ps1'

    function Get-Events($TestRequest) {
        @(Invoke-PlxPageRequest $TestRequest *>&1)
    }
    function Get-Handler($State, $Name) { $State.nodes[$Name].handler }
}

Describe 'page DSL' {
    It 'builds a node tree' {
        $p = New-PlxPage -Title 'T' { New-PlxRow { New-PlxText 'hi'; New-PlxButton 'Go' -ScriptBlock { 1 } } }
        $p.type | Should -Be 'page'
        $p.props.title | Should -Be 'T'
        $p.children[0].type | Should -Be 'row'
        $p.children[0].children.type | Should -Be @('text', 'button')
    }
    It 'ignores stray output inside a block' {
        $p = New-PlxPage { 'not a node'; New-PlxText 'x' }
        $p.children.Count | Should -Be 1
    }
    It 'records the file and line where a control was declared' {
        $f = Join-Path $TestDrive 'Lines.ps1'
        Set-Content $f "New-PlxPage {`n    New-PlxText 'x'`n    New-PlxTextBox -Name A`n}"
        $p = . $f
        $p.children[1].line | Should -Be 3
        $p.children[1].file | Should -Be $f
    }
}

Describe 'Assert-PlxPage' {
    It 'rejects duplicate names' {
        { Assert-PlxPage (New-PlxPage { New-PlxTextBox -Name A; New-PlxCheckbox -Name A }) } | Should -Throw "*'A' is already used*"
    }
    It 'rejects names that cannot be variables' {
        { Assert-PlxPage (New-PlxPage { New-PlxTextBox -Name 'my-box' }) } | Should -Throw '*not a valid name*'
        { Assert-PlxPage (New-PlxPage { New-PlxTextBox -Name Selected }) } | Should -Throw '*reserved*'
        { Assert-PlxPage (New-PlxPage { New-PlxTextBox -Name _ }) } | Should -Throw '*reserved*'
        { Assert-PlxPage (New-PlxPage { New-PlxTextBox -Name __plxThing }) } | Should -Throw '*reserved*'
    }
    It 'checks refresh and output targets' {
        { Assert-PlxPage (New-PlxPage { New-PlxButton 'x' -Refresh Nope -ScriptBlock { } }) } | Should -Throw "*-Refresh 'Nope'*"
        { Assert-PlxPage (New-PlxPage { New-PlxTable -Name T -InputObject @(1); New-PlxButton 'x' -Refresh T -ScriptBlock { } }) } | Should -Throw '*-ScriptBlock*'
        { Assert-PlxPage (New-PlxPage { New-PlxButton 'x' -Output Nope -ScriptBlock { } }) } | Should -Throw "*-Output 'Nope'*"
    }
    It 'requires a page' {
        { Assert-PlxPage (New-PlxText 'x') } | Should -Throw '*New-PlxPage*'
    }
}

Describe 'page requests' {
    BeforeEach {
        $page = . $fixture
        $global:__plxPage = Register-PlxPage $page
        $script:pageState = $global:__plxPage
    }
    AfterAll { Remove-Variable -Name __plxPage -Scope Global -ErrorAction SilentlyContinue }

    It 'sends a layout without scriptblocks, with handler ids' {
        $layoutJson = ConvertTo-PlxJson $pageState.layout
        $layoutJson | Should -Not -Match 'scriptBlock'
        (Get-Handler $pageState 'Inspect') | Should -Match '^h\d+$'
        $pageState.layout.children[1].props.refreshable | Should -BeTrue
    }
    It 'loads layout and initial data, passing warnings through' {
        $ev = Get-Events @{ type = 'load' }
        ($ev | Where-Object { $_.t -eq 'layout' }) | Should -Not -BeNullOrEmpty
        $items = ($ev | Where-Object { $_.t -eq 'data' -and $_.data.name -eq 'Items' }).data
        $items.version | Should -Be 1
        $items.rows.Count | Should -Be 3
        $items.columns | Should -Be @('Name', 'Size')
        ($ev | Where-Object { $_.t -eq 'data' -and $_.data.name -eq 'Sizes' }).data.points[2].y.Size | Should -Be 30
        ($ev | Where-Object { $_.t -eq 'data' -and $_.data.name -eq 'Kinds' }).data.options | Should -Be @('x', 'y')
        $ev | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | Should -Not -BeNullOrEmpty
    }
    It 'hands selected rows to actions as the real objects, with inputs as variables' {
        $null = Get-Events @{ type = 'load' }
        $out = Get-Events @{ type = 'invoke'; handler = (Get-Handler $pageState 'Inspect')
            inputs = @{ Pick = 'a'; Limit = '7'; Loud = $true; Filter = 'item' }
            selections = @{ Items = @{ version = 1; keys = @(1) } } }
        $out | Should -Contain 'same:True'
        $out | Should -Contain 'count:1 selected:1'
        $out | Should -Contain 'pick:a limit:7 loud:True filter:[item]'
    }
    It 'uses defaults for inputs that were not sent' {
        $null = Get-Events @{ type = 'load' }
        (Get-Events @{ type = 'invoke'; handler = (Get-Handler $pageState 'Inspect') }) | Should -Contain 'pick:b limit:5 loud:False filter:[]'
    }
    It 'keeps page variables between actions' {
        $null = Get-Events @{ type = 'load' }
        $null = Get-Events @{ type = 'invoke'; handler = (Get-Handler $pageState 'Count') }
        Get-Events @{ type = 'invoke'; handler = (Get-Handler $pageState 'Count') } | Should -Contain 'counter:2'
    }
    It 'rejects selections from an older version of the data' {
        $null = Get-Events @{ type = 'load' }
        $null = Get-Events @{ type = 'refresh'; names = @('Items') }
        { Get-Events @{ type = 'invoke'; handler = (Get-Handler $pageState 'Inspect'); selections = @{ Items = @{ version = 1; keys = @(0) } } } } |
            Should -Throw '*changed*'
    }
    It 'refreshes after an action and shows messages' {
        $null = Get-Events @{ type = 'load' }
        $ev = Get-Events @{ type = 'invoke'; handler = (Get-Handler $pageState 'Remove'); selections = @{ Items = @{ version = 1; keys = @(0) } } }
        $data = ($ev | Where-Object { $_.t -eq 'data' }).data
        $data.version | Should -Be 2
        $data.rows.Count | Should -Be 2
        $msg = $ev | Where-Object { $_ -is [System.Management.Automation.InformationRecord] -and $_.Tags -contains 'PlxMessage' }
        $msg.MessageData.level | Should -Be 'success'
    }
    It 'refreshes data sources with input values' {
        $null = Get-Events @{ type = 'load' }
        $ev = Get-Events @{ type = 'refresh'; names = @('Items'); inputs = @{ Filter = '2' } }
        ($ev | Where-Object { $_.t -eq 'data' }).data.rows.value.Name | Should -Be @('item2')
    }
    It 'does not let Plectron internals shadow page variables' {
        $global:Name = 'page-name'; $global:State = 'page-state'; $global:node = 'page-node'
        try {
            $global:__plxPage = Register-PlxPage (New-PlxPage {
                    New-PlxTable -Name T -ScriptBlock { [pscustomobject]@{ N = $Name; S = $State; D = $node } }
                    New-PlxButton 'B' -Name B -ScriptBlock { "$Name|$State|$node|$($Request -eq $null)|$($vars -eq $null)" }
                })
            $data = (Get-Events @{ type = 'load' } | Where-Object { $_.t -eq 'data' }).data
            $data.rows[0].value.N | Should -Be 'page-name'
            $data.rows[0].value.S | Should -Be 'page-state'
            $data.rows[0].value.D | Should -Be 'page-node'
            Get-Events @{ type = 'invoke'; handler = $global:__plxPage.nodes.B.handler } | Should -Contain 'page-name|page-state|page-node|True|True'
        } finally { Remove-Variable -Scope Global -Name Name, State, node -ErrorAction SilentlyContinue }
    }
    It 'ignores selections when refreshing' {
        $null = Get-Events @{ type = 'load' }
        $ev = Get-Events @{ type = 'refresh'; names = @('Items'); selections = @{ Items = @{ version = 999; keys = @(0) } } }
        ($ev | Where-Object { $_.t -eq 'data' }).data.rows.Count | Should -Be 3
    }
    It 'caps chart points' {
        $global:__plxPage = Register-PlxPage (New-PlxPage { New-PlxChart -Name C -X N -Y V -ScriptBlock { 1..900 | ForEach-Object { [pscustomobject]@{ N = "$_"; V = $_ } } } })
        $c = (Get-Events @{ type = 'load' } | Where-Object { $_.t -eq 'data' }).data
        $c.points.Count | Should -Be 500
        $c.truncated | Should -BeTrue
    }
    It 'refuses unknown handlers, inputs and refresh targets' {
        { Get-Events @{ type = 'invoke'; handler = 'h999' } } | Should -Throw '*Unknown action*'
        { Get-Events @{ type = 'invoke'; handler = (Get-Handler $pageState 'Count'); inputs = @{ Nope = 1 } } } | Should -Throw '*Unknown input*'
        { Get-Events @{ type = 'refresh'; names = @('Log') } } | Should -Throw '*cannot be refreshed*'
    }
}
