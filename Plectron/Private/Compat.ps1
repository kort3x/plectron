# Helpers that behave identically on Windows PowerShell 5.1 and PowerShell 7+.

$script:PlxJsonDateKind = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')

function ConvertTo-PlxHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [datetime]) { return $InputObject.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-PlxHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-PlxHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Collections.IList] -and $InputObject -isnot [string]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($i in $InputObject) { $list.Add((ConvertTo-PlxHashtable $i)) }
        return , $list.ToArray()
    }
    return $InputObject
}

function ConvertFrom-PlxJson {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    # ConvertFrom-Json -AsHashtable does not exist on 5.1; normalise PSCustomObject instead.
    # PowerShell 7 turns ISO date strings into DateTime; keep them as strings
    # like 5.1 does (-DateKind String on 7.5+, re-formatting on older 7.x).
    if ($script:PlxJsonDateKind) { $obj = ConvertFrom-Json -InputObject $Json -DateKind String }
    else { $obj = ConvertFrom-Json -InputObject $Json }
    return , (ConvertTo-PlxHashtable $obj)
}

function ConvertTo-PlxJson {
    param([AllowNull()]$InputObject, [int]$Depth = 20)
    if ($null -ne $InputObject -and $InputObject -is [array] -and $InputObject.Count -eq 0) { return '[]' }
    return ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress
}

# Reduce an arbitrary .NET object to plain JSON-friendly data: primitives,
# hashtables and arrays. Bounded in depth and size so huge objects
# (processes, services) stay cheap to serialise.
function ConvertTo-PlxValue {
    param([AllowNull()]$InputObject, [int]$Depth = 3, [int]$MaxItems = 100, [int]$MaxProperties = 50)

    if ($null -eq $InputObject) { return $null }
    $v = $InputObject
    if ($v -is [System.Management.Automation.PSObject] -and $v.PSObject.BaseObject -isnot [System.Management.Automation.PSCustomObject]) {
        $v = $v.PSObject.BaseObject
    }
    if ($v -is [string] -or $v -is [char] -or $v -is [guid] -or $v -is [uri] -or $v -is [version]) { return [string]$v }
    if ($v -is [enum]) { return $v.ToString() }
    if ($v -is [bool]) { return $v }
    if ($v -is [datetime]) { return $v.ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    if ($v -is [datetimeoffset]) { return $v.ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    if ($v -is [timespan]) { return $v.ToString() }
    if ($v -is [System.Management.Automation.SwitchParameter]) { return $v.IsPresent }
    if ($v -is [ValueType] -and ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal] -or
            $v -is [single] -or $v -is [byte] -or $v -is [int16] -or $v -is [uint16] -or $v -is [uint32] -or
            $v -is [uint64] -or $v -is [sbyte])) { return $v }
    if ($Depth -le 0) { return [string]$v }

    if ($v -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        $n = 0
        foreach ($k in $v.Keys) {
            if ($n -ge $MaxProperties) { break }
            $h[[string]$k] = ConvertTo-PlxValue $v[$k] -Depth ($Depth - 1) -MaxItems $MaxItems -MaxProperties $MaxProperties
            $n++
        }
        return $h
    }
    if ($v -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($i in $v) {
            if ($list.Count -ge $MaxItems) { break }
            $list.Add((ConvertTo-PlxValue $i -Depth ($Depth - 1) -MaxItems $MaxItems -MaxProperties $MaxProperties))
        }
        return , $list.ToArray()
    }

    $h = [ordered]@{}
    $n = 0
    foreach ($p in ([psobject]$InputObject).PSObject.Properties) {
        if ($n -ge $MaxProperties) { break }
        if ($p.MemberType -notin 'Property', 'NoteProperty', 'ScriptProperty', 'AliasProperty', 'CodeProperty') { continue }
        $pv = $null
        try { $pv = $p.Value } catch { $pv = $null }
        $h[$p.Name] = ConvertTo-PlxValue $pv -Depth ($Depth - 1) -MaxItems $MaxItems -MaxProperties $MaxProperties
        $n++
    }
    return $h
}
