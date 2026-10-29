# A project: what Plectron exposes and how it looks. Comes from plectron.psd1
# at a project root, or is assembled from Start-Plectron's parameters.

$script:PlxProjectKeys = @('Title', 'Logo', 'Accent', 'Modules', 'Scripts', 'Include', 'Exclude', 'Setup', 'Engine', 'Commands')

function New-PlxProject {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Title = 'Plectron',
        [string]$Logo,
        [string]$Accent,
        [string[]]$Modules = @(),
        [string[]]$Scripts = @(),
        [string[]]$Include = @('*'),
        [string[]]$Exclude = @(),
        [string]$Setup,
        [string]$Engine,
        [hashtable]$Commands = @{}
    )
    $rootPath = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
    if ($Accent -and $Accent -notmatch '^#[0-9a-fA-F]{3,8}$') { throw "Accent must be a hex colour like '#0a7cff', not '$Accent'." }

    $resolve = {
        param([string]$Relative, [string]$What, [switch]$MustExist)
        $full = $Relative
        if (-not [IO.Path]::IsPathRooted($Relative)) { $full = Join-Path $rootPath $Relative }
        $full = [IO.Path]::GetFullPath($full)
        if ($MustExist -and -not (Test-Path -LiteralPath $full)) { throw "$What '$Relative' was not found (resolved to $full)." }
        return $full
    }
    $moduleSpecs = @(foreach ($m in $Modules) {
            # Paths are relative to the project; bare names are installed modules.
            if ($m -match '[\\/]' -or $m -match '\.(psd1|psm1|dll)$') { & $resolve $m 'Module' }
            else { $m }
        })
    $logoPath = $null
    if ($Logo) { $logoPath = & $resolve $Logo 'Logo' -MustExist }
    $setupPath = $null
    if ($Setup) { $setupPath = & $resolve $Setup 'Setup script' -MustExist }

    return @{
        Root = $rootPath; Title = $Title; Logo = $logoPath; Accent = $Accent
        Modules = $moduleSpecs
        Scripts = @(foreach ($s in $Scripts) { & $resolve $s 'Scripts folder' -MustExist })
        Include = @($Include); Exclude = @($Exclude); Setup = $setupPath; Engine = $Engine; Commands = $Commands
        Single = $false
    }
}

function Read-PlxProjectConfig {
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    $data = Import-PowerShellDataFile -LiteralPath $file.FullName
    foreach ($key in $data.Keys) {
        if ($script:PlxProjectKeys -notcontains $key) {
            throw "Unknown setting '$key' in $($file.FullName). Valid settings: $($script:PlxProjectKeys -join ', ')."
        }
    }
    return New-PlxProject -Root $file.DirectoryName @data
}

function Get-PlxModuleSpec {
    param([System.Management.Automation.PSModuleInfo]$Module)
    # Modules that ship with PowerShell are imported by name in the child engine.
    if ($Module.ModuleBase -and $Module.ModuleBase.StartsWith($PSHOME, [StringComparison]::OrdinalIgnoreCase)) { return $Module.Name }
    $manifest = Join-Path $Module.ModuleBase "$($Module.Name).psd1"
    if (Test-Path -LiteralPath $manifest) { return $manifest }
    if ($Module.Path) { return $Module.Path }
    return $Module.Name
}

# Decide what to serve from Start-Plectron's parameters:
#   -Config file > -Path with a plectron.psd1 > -Path/-Module/-Command > ./plectron.psd1 > current folder.
function Resolve-PlxProject {
    param([string]$Path, [string[]]$Module, [string]$Config, [object[]]$Command, [string]$Title)
    $project = $null
    if ($Config) { $project = Read-PlxProjectConfig -Path $Config }
    elseif ($Path -and (Test-Path -LiteralPath (Join-Path $Path 'plectron.psd1'))) { $project = Read-PlxProjectConfig -Path (Join-Path $Path 'plectron.psd1') }
    elseif ($Command) {
        $specs = New-Object System.Collections.Generic.List[string]
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($c in $Command) {
            $info = $c
            if ($c -isnot [System.Management.Automation.CommandInfo]) { $info = Get-Command $c -ErrorAction Stop | Select-Object -First 1 }
            if ($info -is [System.Management.Automation.AliasInfo]) { $info = $info.ResolvedCommand }
            if (-not $info.Module) { throw "'$($info.Name)' is not part of a module. Show-Plectron runs commands from modules; put it in a module or use Start-Plectron -Path for scripts." }
            $spec = Get-PlxModuleSpec $info.Module
            if (-not $specs.Contains($spec)) { $specs.Add($spec) }
            $names.Add($info.Name)
        }
        $project = New-PlxProject -Root (Get-Location).Path -Modules $specs.ToArray() -Include $names.ToArray()
        $project.Single = $true
    } elseif ($Path -or $Module) {
        $root = (Get-Location).Path
        if ($Path) { $root = $Path }
        $scripts = @()
        if ($Path) { $scripts = @('.') }  # relative to the root, which is $Path
        $project = New-PlxProject -Root $root -Scripts $scripts -Modules @($Module | Where-Object { $_ } | ForEach-Object {
                    if (Test-Path -LiteralPath $_) { (Resolve-Path -LiteralPath $_).Path } else { $_ } })
    } elseif (Test-Path -LiteralPath 'plectron.psd1') {
        $project = Read-PlxProjectConfig -Path 'plectron.psd1'
    } else {
        $project = New-PlxProject -Root (Get-Location).Path -Scripts @('.')
    }
    if ($Title) { $project.Title = $Title }
    return $project
}

# History is kept per project so runs from different projects don't mix.
function Get-PlxDefaultHistoryRoot {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProjectRoot.ToLowerInvariant())) } finally { $sha.Dispose() }
    $short = (($hash[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
    $leaf = ConvertTo-PlxSlug (Split-Path -Leaf $ProjectRoot)
    return Join-Path (Join-Path (Join-Path (Join-Path $HOME '.plectron') 'projects') "$leaf-$short") 'runs'
}
