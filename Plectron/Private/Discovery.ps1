# Turns .ps1 files into tool schemas (the data the UI renders forms from).

function Get-PlxToolId {
    param([string]$Path, [string]$Root)
    $full = [IO.Path]::GetFullPath($Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $rel = $full
    if ($full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { $rel = $full.Substring($rootFull.Length + 1) }
    $rel = [IO.Path]::ChangeExtension($rel, $null).TrimEnd('.')
    return ($rel.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

function Get-PlxAttributeValue {
    param($Ast)
    try { return $Ast.SafeGetValue() } catch { return $null }
}

function Get-PlxWidget {
    param([type]$Type, [bool]$HasSet)
    $element = $Type
    $isArray = $Type.IsArray
    if ($isArray) { $element = $Type.GetElementType() }

    if ($HasSet) { if ($isArray) { return 'multiselect' } else { return 'select' } }
    if ($isArray) { return 'list' }
    if ($element -eq [System.Management.Automation.SwitchParameter] -or $element -eq [bool]) { return 'toggle' }
    if ($element.IsEnum) { return 'select' }
    if ($element -eq [datetime] -or $element -eq [datetimeoffset]) { return 'datetime' }
    if ($element -eq [securestring]) { return 'password' }
    if ($element -eq [pscredential]) { return 'credential' }
    $numeric = @([byte], [sbyte], [int16], [uint16], [int], [uint32], [long], [uint64], [single], [double], [decimal])
    if ($numeric -contains $element) { return 'number' }
    return 'text'
}

function Get-PlxTypeName {
    param([type]$Type)
    $map = @{
        'System.Management.Automation.SwitchParameter' = 'switch'
        'System.Boolean' = 'bool'; 'System.String' = 'string'; 'System.Int32' = 'int'; 'System.Int64' = 'long'
        'System.Double' = 'double'; 'System.Decimal' = 'decimal'; 'System.DateTime' = 'datetime'
        'System.Security.SecureString' = 'securestring'; 'System.Management.Automation.PSCredential' = 'pscredential'
        'System.Object' = 'object'
    }
    $name = $Type.FullName
    $suffix = ''
    if ($Type.IsArray) { $name = $Type.GetElementType().FullName; $suffix = '[]' }
    if ($map.ContainsKey($name)) { return $map[$name] + $suffix }
    return $name + $suffix
}

function ConvertTo-PlxParameter {
    param([System.Management.Automation.Language.ParameterAst]$Ast, $Help)

    $name = $Ast.Name.VariablePath.UserPath
    $type = $Ast.StaticType
    $p = New-PlxParameterSchema -Name $name -Type $type

    $set = $null
    $sets = New-Object System.Collections.Generic.List[string]
    $mandatoryIn = New-Object System.Collections.Generic.List[string]
    foreach ($attr in $Ast.Attributes) {
        if ($attr -isnot [System.Management.Automation.Language.AttributeAst]) { continue }
        switch ($attr.TypeName.GetReflectionType().Name) {
            'ParameterAttribute' {
                $isMandatory = $false
                $setName = '__AllParameterSets'
                foreach ($na in $attr.NamedArguments) {
                    switch ($na.ArgumentName) {
                        'Mandatory' { $isMandatory = $na.ExpressionOmitted -or [bool](Get-PlxAttributeValue $na.Argument) }
                        'ParameterSetName' { $setName = [string](Get-PlxAttributeValue $na.Argument) }
                        'HelpMessage' { $p.helpMessage = [string](Get-PlxAttributeValue $na.Argument) }
                        'Position' { $p.position = Get-PlxAttributeValue $na.Argument }
                    }
                }
                if ($setName -ne '__AllParameterSets') { $sets.Add($setName) }
                if ($isMandatory) { $mandatoryIn.Add($setName) }
            }
            'ValidateSetAttribute' { $set = @($attr.PositionalArguments | ForEach-Object { [string](Get-PlxAttributeValue $_) }) }
            'ValidateRangeAttribute' {
                if ($attr.PositionalArguments.Count -ge 2) {
                    $p.min = Get-PlxAttributeValue $attr.PositionalArguments[0]
                    $p.max = Get-PlxAttributeValue $attr.PositionalArguments[1]
                }
            }
            'ValidatePatternAttribute' {
                if ($attr.PositionalArguments.Count -ge 1) { $p.pattern = [string](Get-PlxAttributeValue $attr.PositionalArguments[0]) }
            }
        }
    }
    $p.sets = $sets.ToArray()
    $p.mandatoryIn = $mandatoryIn.ToArray()
    Set-PlxParameterWidget -Parameter $p -Type $type -Options $set

    if ($Ast.DefaultValue) {
        $p.defaultText = $Ast.DefaultValue.Extent.Text
        $isLiteral = $Ast.DefaultValue -is [System.Management.Automation.Language.ConstantExpressionAst] -or
            $Ast.DefaultValue -is [System.Management.Automation.Language.ArrayLiteralAst] -or
            $Ast.DefaultValue -is [System.Management.Automation.Language.ArrayExpressionAst] -or
            ($Ast.DefaultValue -is [System.Management.Automation.Language.VariableExpressionAst] -and
            @('true', 'false', 'null') -contains $Ast.DefaultValue.VariablePath.UserPath)
        if ($isLiteral) { $p.default = ConvertTo-PlxValue (Get-PlxAttributeValue $Ast.DefaultValue) }
    }

    if ($Help -and $Help.Parameters) {
        foreach ($k in $Help.Parameters.Keys) {
            if ($k -eq $name) { $p.help = $Help.Parameters[$k].Trim() }
        }
    }
    return $p
}

function New-PlxParameterSchema {
    param([string]$Name, [type]$Type)
    return [ordered]@{
        name = $Name; label = $Name; type = (Get-PlxTypeName $Type); widget = $null
        mandatory = $false; mandatoryIn = @(); sets = @(); position = $null
        default = $null; defaultText = $null; help = $null; helpMessage = $null
        options = $null; min = $null; max = $null; pattern = $null; integer = $false
        placeholder = $null; order = $null
    }
}

# Fills in widget, options and the mandatory flag once type, sets and validation are known.
function Set-PlxParameterWidget {
    param($Parameter, [type]$Type, $Options)
    $element = $Type
    if ($Type.IsArray) { $element = $Type.GetElementType() }
    if ($null -eq $Options -and $element.IsEnum) { $Options = [enum]::GetNames($element) }
    $Parameter.options = $Options
    $Parameter.widget = Get-PlxWidget -Type $Type -HasSet ($null -ne $Options)
    $Parameter.integer = $Parameter.widget -eq 'number' -and @([single], [double], [decimal]) -notcontains $element
    $Parameter.mandatory = @($Parameter.mandatoryIn).Count -gt 0
}

function New-PlxToolSchema {
    param([string]$Id, [string]$Name, [string]$Kind, [string]$Path)
    return [ordered]@{
        id = $Id; kind = $Kind; name = $Name; path = $Path; module = $null; command = $null; title = $Name
        synopsis = $null; description = $null; examples = @(); category = $null; icon = $null
        hidden = $false; output = 'auto'; requiresDesktop = $false; parseError = $null
        parameterSets = @(); defaultParameterSet = $null; parameters = @()
    }
}

# Comment-based help: .SYNOPSIS/.DESCRIPTION/.EXAMPLE, .COMPONENT as category,
# .ROLE Hidden (or Internal) to keep a tool out of the UI.
function Set-PlxToolHelp {
    param($Tool, $Help)
    if (-not $Help) { return }
    if ($Help.Synopsis) { $Tool.synopsis = $Help.Synopsis.Trim() }
    if ($Help.Description) { $Tool.description = $Help.Description.Trim() }
    if ($Help.Examples) { $Tool.examples = @($Help.Examples | ForEach-Object { $_.Trim() }) }
    if ($Help.Component) { $Tool.category = $Help.Component.Trim() }
    if ($Help.Role -and $Help.Role.Trim() -match '^(hidden|internal)$') { $Tool.hidden = $true }
}

# Parameters and parameter sets from a param block (scripts and functions alike).
function Set-PlxToolParameters {
    param($Tool, $ParamBlock, $ParameterAsts, $Help)
    if ($ParamBlock) {
        foreach ($attr in $ParamBlock.Attributes) {
            if ($attr.TypeName.GetReflectionType() -ne [System.Management.Automation.CmdletBindingAttribute]) { continue }
            foreach ($na in $attr.NamedArguments) {
                if ($na.ArgumentName -eq 'DefaultParameterSetName') { $Tool.defaultParameterSet = [string](Get-PlxAttributeValue $na.Argument) }
            }
        }
    }
    $params = @(foreach ($pa in $ParameterAsts) { ConvertTo-PlxParameter -Ast $pa -Help $Help })
    Set-PlxToolParameterList -Tool $Tool -Parameters $params
}

function Set-PlxToolParameterList {
    param($Tool, $Parameters)
    $setNames = New-Object System.Collections.Generic.List[string]
    if ($Tool.defaultParameterSet -and $Tool.defaultParameterSet -ne '__AllParameterSets') { $setNames.Add($Tool.defaultParameterSet) }
    foreach ($p in $Parameters) { foreach ($s in $p.sets) { if (-not $setNames.Contains($s)) { $setNames.Add($s) } } }
    $Tool.parameterSets = $setNames.ToArray()
    if ($setNames.Count -eq 0) { $Tool.defaultParameterSet = $null }
    elseif (-not $setNames.Contains([string]$Tool.defaultParameterSet)) { $Tool.defaultParameterSet = $setNames[0] }
    $i = 0
    foreach ($p in $Parameters) { if ($null -eq $p.order) { $p.order = 1000 + $i }; $i++ }
    $Tool.parameters = @($Parameters)
}

function Get-PlxTool {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)

    $file = Get-Item -LiteralPath $Path
    $tool = New-PlxToolSchema -Id (Get-PlxToolId -Path $file.FullName -Root $Root) -Name $file.BaseName -Kind 'script' -Path $file.FullName

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $tool.parseError = ($errors | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n"
        return $tool
    }

    $help = $ast.GetHelpContent()
    Set-PlxToolHelp -Tool $tool -Help $help
    if ($ast.ScriptRequirements -and $ast.ScriptRequirements.RequiredPSEditions) {
        $tool.requiresDesktop = @($ast.ScriptRequirements.RequiredPSEditions) -contains 'Desktop' -and
            @($ast.ScriptRequirements.RequiredPSEditions) -notcontains 'Core'
    }
    $paramAsts = @()
    if ($ast.ParamBlock) { $paramAsts = $ast.ParamBlock.Parameters }
    Set-PlxToolParameters -Tool $tool -ParamBlock $ast.ParamBlock -ParameterAsts $paramAsts -Help $help

    $sidecar = Get-PlxSidecarPath -Script $file
    if (Test-Path -LiteralPath $sidecar) {
        try { Merge-PlxOverrides -Tool $tool -Data (Import-PowerShellDataFile -LiteralPath $sidecar) }
        catch { $tool.parseError = "Invalid sidecar $([IO.Path]::GetFileName($sidecar)): $($_.Exception.Message)" }
    } else {
        Merge-PlxOverrides -Tool $tool -Data @{}
    }
    return $tool
}

function Get-PlxSidecarPath {
    param([IO.FileInfo]$Script)
    return Join-Path $Script.DirectoryName ($Script.BaseName + '.plectron.psd1')
}

# Applies sidecar or project-config overrides (Title, Category, Parameters, …)
# and re-sorts parameters by their Order.
function Merge-PlxOverrides {
    param($Tool, [hashtable]$Data)
    foreach ($key in 'Title', 'Category', 'Icon', 'Description', 'Output', 'Hidden') {
        if ($Data.ContainsKey($key)) { $Tool[$key.ToLowerInvariant()] = $Data[$key] }
    }
    if ($Data.Parameters) {
        foreach ($p in $Tool.parameters) {
            if (-not $Data.Parameters.ContainsKey($p.name)) { continue }
            $o = $Data.Parameters[$p.name]
            foreach ($key in 'Label', 'Widget', 'Order', 'Placeholder') {
                if ($o.ContainsKey($key)) { $p[$key.ToLowerInvariant()] = $o[$key] }
            }
        }
    }
    $Tool.parameters = @($Tool.parameters | Sort-Object { $_.order })
}

# Scan a folder, reusing cached schemas for files whose timestamps are unchanged.
function Get-PlxTools {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][hashtable]$Cache, [switch]$IncludeHidden)

    $tools = New-Object System.Collections.Generic.List[object]
    foreach ($f in Get-ChildItem -LiteralPath $Root -Filter '*.ps1' -Recurse -File | Sort-Object FullName) {
        $sidecar = Get-PlxSidecarPath -Script $f
        $stamp = $f.LastWriteTimeUtc.Ticks
        if (Test-Path -LiteralPath $sidecar) { $stamp = "$stamp/$((Get-Item -LiteralPath $sidecar).LastWriteTimeUtc.Ticks)" }
        $entry = $Cache[$f.FullName]
        if (-not $entry -or $entry.Stamp -ne "$stamp") {
            $entry = @{ Stamp = "$stamp"; Tool = (Get-PlxTool -Path $f.FullName -Root $Root) }
            $Cache[$f.FullName] = $entry
        }
        if ($IncludeHidden -or -not $entry.Tool.hidden) { $tools.Add($entry.Tool) }
    }
    return $tools.ToArray()
}

function Find-PlxTool {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][hashtable]$Cache, [Parameter(Mandatory)][string]$Id)
    foreach ($t in @(Get-PlxTools -Root $Root -Cache $Cache)) { if ($t.id -eq $Id) { return $t } }
    return $null
}

# ---- module commands ------------------------------------------------------

$script:PlxCommonParameters = @(
    'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable',
    'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm', 'UseTransaction'
)

function ConvertTo-PlxSlug {
    param([string]$Text)
    return ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

# Tool schema for an exported command. Functions reuse the param-block mapping
# used for scripts; compiled cmdlets fall back to parameter metadata.
function ConvertTo-PlxCommandTool {
    param([Parameter(Mandatory)][System.Management.Automation.CommandInfo]$Command, [Parameter(Mandatory)][string]$ModuleId)

    $tool = New-PlxToolSchema -Id "$ModuleId.$(ConvertTo-PlxSlug $Command.Name)" -Name $Command.Name -Kind 'command' -Path $null
    $tool.command = $Command.Name
    $tool.module = $Command.ModuleName

    $ast = $null
    if ($Command -is [System.Management.Automation.FunctionInfo]) { $ast = $Command.ScriptBlock.Ast }
    if ($ast -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        $help = $ast.GetHelpContent()
        Set-PlxToolHelp -Tool $tool -Help $help
        $block = $ast.Body.ParamBlock
        $paramAsts = $ast.Parameters
        if ($block) { $paramAsts = $block.Parameters }
        if (-not $paramAsts) { $paramAsts = @() }
        Set-PlxToolParameters -Tool $tool -ParamBlock $block -ParameterAsts $paramAsts -Help $help
    } else {
        Set-PlxCmdletHelp -Tool $tool -Command $Command
        $tool.defaultParameterSet = $Command.DefaultParameterSet
        $params = @(foreach ($pm in $Command.Parameters.Values) {
                if ($script:PlxCommonParameters -notcontains $pm.Name) { ConvertTo-PlxMetadataParameter -Metadata $pm }
            })
        Set-PlxToolParameterList -Tool $tool -Parameters $params
    }

    $primitive = @([string], [bool], [int], [long], [double], [decimal], [void])
    foreach ($ot in $Command.OutputType) {
        if ($ot.Type -and $primitive -notcontains $ot.Type) { $tool.output = 'table'; break }
        if (-not $ot.Type -and $ot.Name) { $tool.output = 'table'; break }
    }
    Merge-PlxOverrides -Tool $tool -Data @{}
    return $tool
}

function Set-PlxCmdletHelp {
    param($Tool, $Command)
    $help = $null
    try { $help = Get-Help $Command.Name -ErrorAction Stop } catch { return }
    # Without installed help, Get-Help only echoes the syntax.
    if ($help.Synopsis -and -not $help.Synopsis.Trim().StartsWith($Command.Name)) { $Tool.synopsis = $help.Synopsis.Trim() }
    if ($help.description) { $Tool.description = (@($help.description | ForEach-Object { $_.Text }) -join "`n").Trim() }
}

function ConvertTo-PlxMetadataParameter {
    param([System.Management.Automation.ParameterMetadata]$Metadata)
    $p = New-PlxParameterSchema -Name $Metadata.Name -Type $Metadata.ParameterType
    $options = $null
    foreach ($attr in $Metadata.Attributes) {
        if ($attr -is [System.Management.Automation.ValidateSetAttribute]) { $options = @($attr.ValidValues) }
        elseif ($attr -is [System.Management.Automation.ValidateRangeAttribute]) { $p.min = $attr.MinRange; $p.max = $attr.MaxRange }
        elseif ($attr -is [System.Management.Automation.ValidatePatternAttribute]) { $p.pattern = $attr.RegexPattern }
    }
    $sets = New-Object System.Collections.Generic.List[string]
    $mandatoryIn = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Metadata.ParameterSets.GetEnumerator()) {
        if ($entry.Key -ne '__AllParameterSets') { $sets.Add($entry.Key) }
        if ($entry.Value.IsMandatory) { $mandatoryIn.Add($entry.Key) }
        if ($entry.Value.HelpMessage) { $p.helpMessage = $entry.Value.HelpMessage }
    }
    $p.sets = $sets.ToArray()
    $p.mandatoryIn = $mandatoryIn.ToArray()
    Set-PlxParameterWidget -Parameter $p -Type $Metadata.ParameterType -Options $options
    return $p
}
