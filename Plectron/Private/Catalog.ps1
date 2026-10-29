# The catalog: every tool a project exposes (scripts + module commands), with
# project overrides and Include/Exclude applied. The server only runs tools
# found here.

function Get-PlxModuleStamp {
    param([string]$Module, [string]$Setup)
    $stamp = $Module
    if (Test-Path -LiteralPath $Module -PathType Leaf) {
        $max = 0
        foreach ($f in Get-ChildItem -LiteralPath (Split-Path $Module) -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.dll') {
            if ($f.LastWriteTimeUtc.Ticks -gt $max) { $max = $f.LastWriteTimeUtc.Ticks }
        }
        $stamp = "$stamp/$max"
    }
    if ($Setup -and (Test-Path -LiteralPath $Setup)) { $stamp = "$stamp/$((Get-Item -LiteralPath $Setup).LastWriteTimeUtc.Ticks)" }
    return $stamp
}

# Import the module in a child process (with the configured engine) and
# describe its exported commands. Keeps project modules out of the server.
function Invoke-PlxDescribe {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Module)
    $engine = Resolve-PlxEngine -Preferred $State.Engine
    $jobPath = Join-Path ([IO.Path]::GetTempPath()) "plectron-$([guid]::NewGuid().ToString('N')).json"
    Write-PlxPrivateFile -Path $jobPath -Content (ConvertTo-PlxJson @{ module = $Module; setup = $State.Project.Setup })
    $describeHost = Join-Path (Split-Path $State.RunHostPath) 'Describe.ps1'
    $arguments = @('-NoProfile', '-NonInteractive')
    if (Test-PlxWindows) { $arguments += @('-ExecutionPolicy', 'Bypass') }
    $arguments += @('-File', $describeHost, '-JobPath', $jobPath)

    Push-Location -LiteralPath $State.Root
    try { $lines = @(& $engine @arguments 2>&1 | ForEach-Object { [string]$_ }) }
    finally {
        Pop-Location
        if (Test-Path -LiteralPath $jobPath) { Remove-Item -LiteralPath $jobPath -Force }
    }
    foreach ($line in $lines) {
        $e = ConvertFrom-PlxEventLine $line
        if ($e -and $e.t -eq 'describe') { return $e.data }
    }
    return @{ error = "Describing '$Module' produced no result.`n$($lines -join "`n")" }
}

function Get-PlxModuleTools {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Module)
    $stamp = Get-PlxModuleStamp -Module $Module -Setup $State.Project.Setup
    $entry = $State.CommandCache[$Module]
    if (-not $entry -or $entry.Stamp -ne $stamp) {
        $result = Invoke-PlxDescribe -State $State -Module $Module
        $tools = @()
        if ($result.error) {
            $name = [IO.Path]::GetFileNameWithoutExtension($Module)
            $broken = New-PlxToolSchema -Id (ConvertTo-PlxSlug $name) -Name $name -Kind 'command' -Path $Module
            $broken.parseError = "Could not load module '$Module': $($result.error)"
            $tools = @($broken)
        } else {
            $tools = @($result.tools | ForEach-Object { $_.path = $Module; $_ })
        }
        $entry = @{ Stamp = $stamp; Tools = $tools }
        $State.CommandCache[$Module] = $entry
    }
    return $entry.Tools
}

function Test-PlxToolSelected {
    param($Project, $Tool)
    if ($Tool.kind -eq 'command' -and -not $Tool.command) { return $true }  # a module that failed to load
    $included = $false
    foreach ($pattern in $Project.Include) { if ($Tool.name -like $pattern) { $included = $true } }
    foreach ($pattern in $Project.Exclude) { if ($Tool.name -like $pattern) { $included = $false } }
    return $included
}

function Get-PlxCatalog {
    param([Parameter(Mandatory)][hashtable]$State, [switch]$IncludeHidden)
    $project = $State.Project
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($dir in $project.Scripts) { foreach ($t in @(Get-PlxTools -Root $dir -Cache $State.ToolCache -IncludeHidden)) { $all.Add($t) } }
    foreach ($m in $project.Modules) { foreach ($t in @(Get-PlxModuleTools -State $State -Module $m)) { $all.Add($t) } }

    $seen = @{}
    foreach ($tool in $all) {
        if ($seen.ContainsKey($tool.id)) { continue }
        $seen[$tool.id] = $true
        if ($project.Commands.ContainsKey($tool.name)) { Merge-PlxOverrides -Tool $tool -Data $project.Commands[$tool.name] }
        if (-not (Test-PlxToolSelected -Project $project -Tool $tool)) { continue }
        if ($tool.hidden -and -not $IncludeHidden) { continue }
        $tool
    }
}

function Find-PlxCatalogTool {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Id)
    foreach ($t in @(Get-PlxCatalog -State $State)) { if ($t.id -eq $Id) { return $t } }
    return $null
}
