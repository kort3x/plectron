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
    $p = [ordered]@{
        name = $name; label = $name; type = (Get-PlxTypeName $type); widget = $null
        mandatory = $false; mandatoryIn = @(); sets = @(); position = $null
        default = $null; defaultText = $null; help = $null; helpMessage = $null
        options = $null; min = $null; max = $null; pattern = $null; integer = $false
        placeholder = $null; order = $null
    }

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
    $p.mandatory = $mandatoryIn.Count -gt 0

    $element = $type
    if ($type.IsArray) { $element = $type.GetElementType() }
    if ($null -eq $set -and $element.IsEnum) { $set = [enum]::GetNames($element) }
    $p.options = $set
    $p.widget = Get-PlxWidget -Type $type -HasSet ($null -ne $set)
    $p.integer = $p.widget -eq 'number' -and @([single], [double], [decimal]) -notcontains $element

    if ($Ast.DefaultValue) {
        $p.defaultText = $Ast.DefaultValue.Extent.Text
        $isLiteral = $Ast.DefaultValue -is [System.Management.Automation.Language.ConstantExpressionAst] -or
            $Ast.DefaultValue -is [System.Management.Automation.Language.ArrayLiteralAst] -or
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

function Get-PlxTool {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)

    $file = Get-Item -LiteralPath $Path
    $tool = [ordered]@{
        id = (Get-PlxToolId -Path $file.FullName -Root $Root)
        name = $file.BaseName; path = $file.FullName; title = $file.BaseName
        synopsis = $null; description = $null; examples = @(); category = $null; icon = $null
        hidden = $false; output = 'auto'; requiresDesktop = $false; parseError = $null
        parameterSets = @(); defaultParameterSet = $null; parameters = @()
    }

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $tool.parseError = ($errors | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n"
        return $tool
    }

    $help = $ast.GetHelpContent()
    if ($help) {
        if ($help.Synopsis) { $tool.synopsis = $help.Synopsis.Trim() }
        if ($help.Description) { $tool.description = $help.Description.Trim() }
        if ($help.Examples) { $tool.examples = @($help.Examples | ForEach-Object { $_.Trim() }) }
    }
    if ($ast.ScriptRequirements -and $ast.ScriptRequirements.RequiredPSEditions) {
        $tool.requiresDesktop = @($ast.ScriptRequirements.RequiredPSEditions) -contains 'Desktop' -and
            @($ast.ScriptRequirements.RequiredPSEditions) -notcontains 'Core'
    }

    $params = New-Object System.Collections.Generic.List[object]
    if ($ast.ParamBlock) {
        foreach ($attr in $ast.ParamBlock.Attributes) {
            if ($attr.TypeName.GetReflectionType() -ne [System.Management.Automation.CmdletBindingAttribute]) { continue }
            foreach ($na in $attr.NamedArguments) {
                if ($na.ArgumentName -eq 'DefaultParameterSetName') { $tool.defaultParameterSet = [string](Get-PlxAttributeValue $na.Argument) }
            }
        }
        foreach ($pa in $ast.ParamBlock.Parameters) { $params.Add((ConvertTo-PlxParameter -Ast $pa -Help $help)) }
    }

    $setNames = New-Object System.Collections.Generic.List[string]
    if ($tool.defaultParameterSet) { $setNames.Add($tool.defaultParameterSet) }
    foreach ($p in $params) { foreach ($s in $p.sets) { if (-not $setNames.Contains($s)) { $setNames.Add($s) } } }
    $tool.parameterSets = $setNames.ToArray()
    if (-not $tool.defaultParameterSet -and $setNames.Count -gt 0) { $tool.defaultParameterSet = $setNames[0] }

    $sidecar = Join-Path $file.DirectoryName ($file.BaseName + '.plectron.psd1')
    if (Test-Path -LiteralPath $sidecar) { Merge-PlxSidecar -Tool $tool -Parameters $params -Path $sidecar }

    $i = 0
    foreach ($p in $params) { if ($null -eq $p.order) { $p.order = 1000 + $i }; $i++ }
    $tool.parameters = @($params | Sort-Object { $_.order })
    return $tool
}

function Merge-PlxSidecar {
    param($Tool, $Parameters, [string]$Path)
    try { $data = Import-PowerShellDataFile -LiteralPath $Path }
    catch { $Tool.parseError = "Invalid sidecar $([IO.Path]::GetFileName($Path)): $($_.Exception.Message)"; return }

    foreach ($key in 'Title', 'Category', 'Icon', 'Description', 'Output', 'Hidden') {
        if ($data.ContainsKey($key)) { $Tool[$key.ToLowerInvariant()] = $data[$key] }
    }
    if ($data.Parameters) {
        foreach ($p in $Parameters) {
            if (-not $data.Parameters.ContainsKey($p.name)) { continue }
            $o = $data.Parameters[$p.name]
            foreach ($key in 'Label', 'Widget', 'Order', 'Placeholder') {
                if ($o.ContainsKey($key)) { $p[$key.ToLowerInvariant()] = $o[$key] }
            }
        }
    }
}

# Scan a folder, reusing cached schemas for files whose timestamps are unchanged.
function Get-PlxTools {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][hashtable]$Cache, [switch]$IncludeHidden)

    $tools = New-Object System.Collections.Generic.List[object]
    foreach ($f in Get-ChildItem -LiteralPath $Root -Filter '*.ps1' -Recurse -File | Sort-Object FullName) {
        $sidecar = Join-Path $f.DirectoryName ($f.BaseName + '.plectron.psd1')
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
