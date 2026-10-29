# Layout DSL for custom pages. Each command returns a node:
#   @{ plx = 'node'; type; name; props; children; file; line }
# Pages are evaluated inside a page process (RunHost/PageHost.ps1), which keeps
# the scriptblocks and the real objects they return.

function New-PlxNode {
    param([string]$Type, [string]$Name, [hashtable]$Props, [scriptblock]$Content, $Invocation)
    $children = @()
    if ($Content) {
        $children = @(& $Content | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['plx'] -eq 'node' })
    }
    return [ordered]@{
        plx = 'node'; type = $Type; name = $Name; props = $Props; children = $children
        file = $Invocation.ScriptName; line = $Invocation.ScriptLineNumber
    }
}

function New-PlxPage {
    <#
    .SYNOPSIS
    The root of a custom page. Everything inside -Content is laid out top to bottom.
    .EXAMPLE
    New-PlxPage -Title 'Task manager' { New-PlxTable -Name Processes -ScriptBlock { Get-Process } }
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][scriptblock]$Content, [string]$Title = 'Page', [string]$Description)
    New-PlxNode -Type 'page' -Props @{ title = $Title; description = $Description } -Content $Content -Invocation $MyInvocation
}

function New-PlxRow {
    <# .SYNOPSIS Lays out its children side by side (wrapping on narrow screens). #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][scriptblock]$Content)
    New-PlxNode -Type 'row' -Props @{} -Content $Content -Invocation $MyInvocation
}

function New-PlxColumn {
    <# .SYNOPSIS A column inside a row. -Width is a relative weight (default 1). #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][scriptblock]$Content, [ValidateRange(1, 12)][int]$Width = 1)
    New-PlxNode -Type 'column' -Props @{ width = $Width } -Content $Content -Invocation $MyInvocation
}

function New-PlxCard {
    <# .SYNOPSIS A titled panel. #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][scriptblock]$Content, [string]$Title)
    New-PlxNode -Type 'card' -Props @{ title = $Title } -Content $Content -Invocation $MyInvocation
}

function New-PlxTabs {
    <# .SYNOPSIS A set of tabs; put New-PlxTab blocks inside. #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][scriptblock]$Content)
    New-PlxNode -Type 'tabs' -Props @{} -Content $Content -Invocation $MyInvocation
}

function New-PlxTab {
    <# .SYNOPSIS One tab inside New-PlxTabs. #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Title, [Parameter(Position = 1)][scriptblock]$Content)
    New-PlxNode -Type 'tab' -Props @{ title = $Title } -Content $Content -Invocation $MyInvocation
}

function New-PlxTable {
    <#
    .SYNOPSIS
    A table of objects. Actions see the selected (real) objects as $<Name>.
    .PARAMETER ScriptBlock
    Produces the rows. Runs again when the table is refreshed and can use input values ($<InputName>).
    .PARAMETER InputObject
    Fixed rows, evaluated once when the page loads.
    .PARAMETER Property
    Columns to show (default: the objects' default display properties, or all).
    #>
    [CmdletBinding(DefaultParameterSetName = 'ScriptBlock')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory, ParameterSetName = 'ScriptBlock')][scriptblock]$ScriptBlock,
        [Parameter(Mandatory, ParameterSetName = 'InputObject')][AllowEmptyCollection()][object[]]$InputObject,
        [string[]]$Property,
        [ValidateSet('None', 'Single', 'Multiple')][string]$Selection = 'Multiple',
        [ValidateRange(0, 86400)][int]$AutoRefresh = 0,
        [string]$Title
    )
    New-PlxNode -Type 'table' -Name $Name -Invocation $MyInvocation -Props @{
        scriptBlock = $ScriptBlock; inputObject = $InputObject; property = $Property
        selection = $Selection.ToLowerInvariant(); autoRefresh = $AutoRefresh; title = $Title
    }
}

function New-PlxChart {
    <#
    .SYNOPSIS
    A bar or line chart. -X names the label property, -Y one or more numeric properties.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ScriptBlock')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Bar', 'Line')][string]$Type = 'Bar',
        [Parameter(Mandatory)][string]$X,
        [Parameter(Mandatory)][string[]]$Y,
        [Parameter(Mandatory, ParameterSetName = 'ScriptBlock')][scriptblock]$ScriptBlock,
        [Parameter(Mandatory, ParameterSetName = 'InputObject')][AllowEmptyCollection()][object[]]$InputObject,
        [ValidateRange(0, 86400)][int]$AutoRefresh = 0,
        [string]$Title
    )
    New-PlxNode -Type 'chart' -Name $Name -Invocation $MyInvocation -Props @{
        chartType = $Type.ToLowerInvariant(); x = $X; y = $Y; scriptBlock = $ScriptBlock; inputObject = $InputObject
        autoRefresh = $AutoRefresh; title = $Title
    }
}

function New-PlxTextBox {
    <# .SYNOPSIS A text input. Actions and data sources see its value as $<Name>. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Label, [string]$Default = '', [string]$Placeholder, [switch]$Multiline, [string[]]$Refresh)
    New-PlxNode -Type 'textbox' -Name $Name -Invocation $MyInvocation -Props @{
        label = $Label; default = $Default; placeholder = $Placeholder; multiline = [bool]$Multiline; refresh = $Refresh
    }
}

function New-PlxDropdown {
    <# .SYNOPSIS A drop-down with fixed -Options or options produced by -ScriptBlock. Value: $<Name>. #>
    [CmdletBinding(DefaultParameterSetName = 'Options')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory, ParameterSetName = 'Options')][string[]]$Options,
        [Parameter(Mandatory, ParameterSetName = 'ScriptBlock')][scriptblock]$ScriptBlock,
        [string]$Label, [string]$Default, [string[]]$Refresh
    )
    New-PlxNode -Type 'dropdown' -Name $Name -Invocation $MyInvocation -Props @{
        options = $Options; scriptBlock = $ScriptBlock; label = $Label; default = $Default; refresh = $Refresh
    }
}

function New-PlxCheckbox {
    <# .SYNOPSIS A checkbox. Value: $<Name> ($true/$false). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Label, [bool]$Default = $false, [string[]]$Refresh)
    New-PlxNode -Type 'checkbox' -Name $Name -Invocation $MyInvocation -Props @{ label = $Label; default = $Default; refresh = $Refresh }
}

function New-PlxNumber {
    <# .SYNOPSIS A number input. Value: $<Name> (a [double], or $null when empty). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Label, [Nullable[double]]$Default, [Nullable[double]]$Min, [Nullable[double]]$Max, [string[]]$Refresh)
    New-PlxNode -Type 'number' -Name $Name -Invocation $MyInvocation -Props @{
        label = $Label; default = $Default; min = $Min; max = $Max; refresh = $Refresh
    }
}

function New-PlxButton {
    <#
    .SYNOPSIS
    Runs -ScriptBlock in the page process. Selections and input values are available as variables.
    .PARAMETER Refresh
    Tables, charts or drop-downs to reload after the action succeeds.
    .PARAMETER Confirm
    Ask this question before running.
    .PARAMETER Output
    Name of a New-PlxOutput panel to stream into (default: a drawer).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Text,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$Name, [string[]]$Refresh, [string]$Confirm,
        [ValidateSet('Default', 'Primary', 'Danger')][string]$Variant = 'Default',
        [string]$Output
    )
    New-PlxNode -Type 'button' -Name $Name -Invocation $MyInvocation -Props @{
        text = $Text; scriptBlock = $ScriptBlock; refresh = $Refresh; confirm = $Confirm
        variant = $Variant.ToLowerInvariant(); output = $Output
    }
}

function New-PlxText {
    <# .SYNOPSIS Static text, optionally as Markdown (headings, emphasis, code, lists, links). #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Text, [switch]$Markdown)
    New-PlxNode -Type 'text' -Invocation $MyInvocation -Props @{ text = $Text; markdown = [bool]$Markdown }
}

function New-PlxOutput {
    <# .SYNOPSIS A console panel that buttons can stream into with -Output <Name>. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Title)
    New-PlxNode -Type 'output' -Name $Name -Invocation $MyInvocation -Props @{ title = $Title }
}

function Show-PlxMessage {
    <#
    .SYNOPSIS
    Inside a page action: show a toast in the browser. Elsewhere it just writes the text.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Text, [ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Level = 'Info')
    $data = [pscustomobject]@{ text = $Text; level = $Level.ToLowerInvariant() }
    $data | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.text } -Force
    Write-Information -MessageData $data -Tags 'PlxMessage' -InformationAction Continue
}
