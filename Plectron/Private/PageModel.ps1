# Page model for custom pages: validation, the layout sent to the browser, and
# request handling. Runs inside the page process (RunHost/PageHost.ps1), where
# it is dot-sourced next to the page script so scriptblocks see injected variables.

$script:PlxDataTypes = @('table', 'chart', 'dropdown')
$script:PlxInputTypes = @('textbox', 'dropdown', 'checkbox', 'number')
$script:PlxReservedNames = @('Selected', '_', 'Input', 'PSItem', 'args', 'this', 'Host', 'true', 'false', 'null', 'Error', 'PID', 'PWD', 'HOME', 'PSCmdlet', 'MyInvocation', 'Matches', 'LASTEXITCODE')
$script:PlxMaxRows = 2000
$script:PlxMaxPoints = 500

function Get-PlxPageNodes {
    param($Node)
    $Node
    foreach ($c in $Node.children) { Get-PlxPageNodes $c }
}

function Get-PlxNodeLocation {
    param($Node)
    if ($Node.file) { return "$([IO.Path]::GetFileName($Node.file)) line $($Node.line)" }
    return "line $($Node.line)"
}

function Assert-PlxPage {
    param($Page)
    if (-not $Page -or $Page['plx'] -ne 'node' -or $Page.type -ne 'page') { throw 'The page script must output a New-PlxPage.' }
    $named = @{}
    foreach ($n in (Get-PlxPageNodes $Page)) {
        if (-not $n.name) { continue }
        $where = Get-PlxNodeLocation $n
        if ($n.name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "${where}: '$($n.name)' is not a valid name (letters, digits and _ only; it becomes the variable `$$($n.name))." }
        if ($script:PlxReservedNames -contains $n.name -or $n.name -like '__plx*') { throw "${where}: '$($n.name)' is reserved; choose another name." }
        if ($named.ContainsKey($n.name)) { throw "${where}: the name '$($n.name)' is already used." }
        $named[$n.name] = $n
    }
    foreach ($n in (Get-PlxPageNodes $Page)) {
        $where = Get-PlxNodeLocation $n
        foreach ($target in @($n.props.refresh)) {
            if (-not $target) { continue }
            $t = $named[$target]
            if (-not $t -or $script:PlxDataTypes -notcontains $t.type -or -not $t.props.scriptBlock) {
                throw "${where}: -Refresh '$target' must name a table, chart or drop-down that has a -ScriptBlock."
            }
        }
        if ($n.type -eq 'button' -and $n.props.output) {
            $o = $named[$n.props.output]
            if (-not $o -or $o.type -ne 'output') { throw "${where}: -Output '$($n.props.output)' must name a New-PlxOutput." }
        }
    }
}

# Build the page state: handler ids for buttons, data slots for data nodes, and
# the layout (without scriptblocks) for the browser.
function Register-PlxPage {
    param($Page)
    Assert-PlxPage $Page
    $state = @{ page = $Page; handlers = @{}; nodes = @{}; data = @{}; layout = $null }
    $i = 0
    foreach ($n in (Get-PlxPageNodes $Page)) {
        if ($n.name) { $state.nodes[$n.name] = $n }
        if ($n.type -eq 'button') {
            $i++
            $n.handler = "h$i"
            $state.handlers[$n.handler] = $n
        }
        if ($script:PlxDataTypes -contains $n.type -and ($n.props.scriptBlock -or $n.type -ne 'dropdown')) {
            $state.data[$n.name] = @{ version = 0; items = @() }
        }
    }
    $state.layout = ConvertTo-PlxLayout $Page
    return $state
}

function ConvertTo-PlxLayout {
    param($Node)
    $props = [ordered]@{}
    foreach ($k in $Node.props.Keys) {
        if ($k -eq 'scriptBlock' -or $k -eq 'inputObject') { continue }
        $props[$k] = $Node.props[$k]
    }
    if ($script:PlxDataTypes -contains $Node.type) { $props.refreshable = [bool]$Node.props.scriptBlock }
    return [ordered]@{
        type = $Node.type; name = $Node.name; handler = $Node['handler']; props = $props
        children = @(foreach ($c in $Node.children) { ConvertTo-PlxLayout $c })
    }
}

function New-PlxPageEvent {
    param([string]$Type, $Data)
    return [pscustomobject]@{ PSTypeName = 'Plx.Event'; t = $Type; data = $Data }
}

# Variables for a handler: each input's value, each table's selected objects,
# and $Selected when the page has exactly one table.
function Get-PlxPageVariables {
    param($State, $Request)
    $vars = @{}
    foreach ($n in $State.nodes.Values) {
        if ($script:PlxInputTypes -contains $n.type) { $vars[$n.name] = ConvertTo-PlxInputValue -Node $n -Value $n.props.default }
    }
    if ($Request.inputs) {
        foreach ($k in $Request.inputs.Keys) {
            $n = $State.nodes[$k]
            if (-not $n -or $script:PlxInputTypes -notcontains $n.type) { throw "Unknown input '$k'." }
            $vars[$k] = ConvertTo-PlxInputValue -Node $n -Value $Request.inputs[$k]
        }
    }
    $tables = @($State.nodes.Values | Where-Object { $_.type -eq 'table' })
    foreach ($t in $tables) {
        $selected = @()
        $sel = $null
        if ($Request.selections) { $sel = $Request.selections[$t.name] }
        if ($sel -and @($sel.keys).Count -gt 0) {
            $slot = $State.data[$t.name]
            if ([int]$sel.version -ne $slot.version) { throw "The data in '$($t.name)' has changed since you selected rows. Select them again." }
            $selected = @(foreach ($key in $sel.keys) {
                    $index = [int]$key
                    if ($index -lt 0 -or $index -ge $slot.items.Count) { throw "Row $key is not in '$($t.name)'." }
                    $slot.items[$index]
                })
        }
        if ($t.props.selection -eq 'single') { $vars[$t.name] = $selected | Select-Object -First 1 }
        else { $vars[$t.name] = $selected }
    }
    if ($tables.Count -eq 1) { $vars['Selected'] = $vars[$tables[0].name] }
    return $vars
}

function ConvertTo-PlxInputValue {
    param($Node, $Value)
    switch ($Node.type) {
        'checkbox' { return [bool]$Value }
        'number' {
            if ($null -eq $Value -or "$Value" -eq '') { return $null }
            return [double]$Value
        }
        default { if ($null -eq $Value) { return '' } else { return [string]$Value } }
    }
}

# Runs a page scriptblock with the variables in scope. Kept as a plain function
# (not a module member) so the scriptblock sees them through dynamic scoping.
# Every function on the way here names its parameters and locals __plx* so
# none of them can shadow the page's own variables.
function Invoke-PlxPageScript {
    param($__plxScript, $__plxVariables)
    foreach ($__plxName in $__plxVariables.Keys) { Set-Variable -Name $__plxName -Value $__plxVariables[$__plxName] }
    & $__plxScript
}

function Test-PlxStreamRecord {
    param($Item)
    $base = $Item
    if ($Item -is [System.Management.Automation.PSObject]) { $base = $Item.PSObject.BaseObject }
    return $base -is [System.Management.Automation.ErrorRecord] -or $base -is [System.Management.Automation.WarningRecord] -or
        $base -is [System.Management.Automation.InformationRecord] -or $base -is [System.Management.Automation.VerboseRecord] -or
        $base -is [System.Management.Automation.DebugRecord]
}

function Update-PlxPageData {
    param($__plxState, [string]$__plxDataName, $__plxVariables)
    $__plxNode = $__plxState.nodes[$__plxDataName]
    $__plxItems = New-Object System.Collections.Generic.List[object]
    if ($__plxNode.props.scriptBlock) {
        # Stream records (warnings, errors, messages) pass through; objects become the data.
        foreach ($__plxItem in @(Invoke-PlxPageScript $__plxNode.props.scriptBlock $__plxVariables *>&1)) {
            if (Test-PlxStreamRecord $__plxItem) { $__plxItem } else { $__plxItems.Add($__plxItem) }
        }
    } elseif ($null -ne $__plxNode.props.inputObject) {
        foreach ($__plxItem in $__plxNode.props.inputObject) { $__plxItems.Add($__plxItem) }
    } elseif ($__plxNode.type -eq 'dropdown') {
        return
    }
    $__plxSlot = $__plxState.data[$__plxDataName]
    $__plxSlot.version++
    $__plxSlot.items = $__plxItems.ToArray()
    New-PlxPageEvent 'data' (ConvertTo-PlxPageData -Node $__plxNode -Slot $__plxSlot)
}

function ConvertTo-PlxPageData {
    param($Node, $Slot)
    $data = [ordered]@{ name = $Node.name; version = $Slot.version; count = $Slot.items.Count }
    switch ($Node.type) {
        'table' {
            $columns = $Node.props.property
            if (-not $columns -and $Slot.items.Count -gt 0) {
                $first = $Slot.items[0]
                $standard = $null
                if ($null -ne $first) { $standard = $first.PSObject.Members['PSStandardMembers'] }
                if ($standard -and $standard.Value.DefaultDisplayPropertySet) { $columns = @($standard.Value.DefaultDisplayPropertySet.ReferencedPropertyNames) }
            }
            $rows = New-Object System.Collections.Generic.List[object]
            for ($i = 0; $i -lt [Math]::Min($Slot.items.Count, $script:PlxMaxRows); $i++) {
                $rows.Add([ordered]@{ key = $i; value = (ConvertTo-PlxValue $Slot.items[$i] -Depth 2) })
            }
            $data.columns = $columns
            $data.rows = $rows.ToArray()
            $data.truncated = $Slot.items.Count -gt $script:PlxMaxRows
        }
        'chart' {
            $data.truncated = $Slot.items.Count -gt $script:PlxMaxPoints
            $data.points = @(foreach ($item in ($Slot.items | Select-Object -First $script:PlxMaxPoints)) {
                    $y = [ordered]@{}
                    foreach ($p in $Node.props.y) {
                        $v = $item.$p
                        if ($null -ne $v) { try { $v = [double]$v } catch { $v = $null } }
                        $y[$p] = $v
                    }
                    [ordered]@{ x = [string]$item.($Node.props.x); y = $y }
                })
        }
        'dropdown' { $data.options = @(foreach ($item in $Slot.items) { [string]$item }) }
    }
    return $data
}

# Entry point for one request from the browser. Emits Plx.Event objects and the
# action's own stream records; the page host turns both into protocol events.
function Invoke-PlxPageRequest {
    param($__plxRequest)
    $__plxState = $global:__plxPage
    switch ($__plxRequest.type) {
        'load' {
            New-PlxPageEvent 'layout' $__plxState.layout
            $__plxVars = Get-PlxPageVariables -State $__plxState -Request @{}
            foreach ($__plxName in @($__plxState.data.Keys | Sort-Object)) { Update-PlxPageData $__plxState $__plxName $__plxVars }
        }
        'refresh' {
            # Data sources see input values only; selections are for actions.
            $__plxVars = Get-PlxPageVariables -State $__plxState -Request @{ inputs = $__plxRequest.inputs }
            foreach ($__plxName in @($__plxRequest.names)) {
                if (-not $__plxState.data.ContainsKey([string]$__plxName) -or -not $__plxState.nodes[[string]$__plxName].props.scriptBlock) { throw "'$__plxName' cannot be refreshed." }
                Update-PlxPageData $__plxState ([string]$__plxName) $__plxVars
            }
        }
        'invoke' {
            $__plxButton = $__plxState.handlers[[string]$__plxRequest.handler]
            if (-not $__plxButton) { throw "Unknown action '$($__plxRequest.handler)'." }
            $__plxVars = Get-PlxPageVariables -State $__plxState -Request $__plxRequest
            Invoke-PlxPageScript $__plxButton.props.scriptBlock $__plxVars *>&1
            $__plxVars = Get-PlxPageVariables -State $__plxState -Request @{ inputs = $__plxRequest.inputs }
            foreach ($__plxName in @($__plxButton.props.refresh)) { if ($__plxName) { Update-PlxPageData $__plxState $__plxName $__plxVars } }
        }
        default { throw "Unknown request type '$($__plxRequest.type)'." }
    }
}
