function Start-Plectron {
    <#
    .SYNOPSIS
    Serve a project's PowerShell commands and scripts as a local web UI.
    .DESCRIPTION
    Without parameters, Start-Plectron uses ./plectron.psd1 when it exists and
    otherwise serves the .ps1 scripts in the current folder.

    Every exported command of a module (-Module) and every .ps1 script under a
    scripts folder (-Path) becomes a tool with a form generated from its
    param() block and comment-based help. The server listens on localhost only
    and is protected by a per-session token embedded in the printed URL.
    .PARAMETER Path
    A project folder containing plectron.psd1, or a folder of .ps1 scripts.
    .PARAMETER Module
    Modules whose exported commands become tools: a .psd1/.psm1 path or the name of an installed module.
    .PARAMETER Config
    Path to a plectron.psd1 project file.
    .PARAMETER Command
    Individual commands to serve (names or Get-Command results). See also Show-Plectron.
    .PARAMETER Page
    Custom page scripts (files that output a New-PlxPage) to serve.
    .PARAMETER Title
    Title shown in the UI. Overrides the project file.
    .PARAMETER Port
    Port to listen on. 0 (the default) picks a free port.
    .PARAMETER Engine
    PowerShell executable used to run tools (e.g. pwsh, powershell.exe or a full path).
    Defaults to the project's Engine setting, then to the engine running Plectron.
    .PARAMETER HistoryPath
    Where run history is kept. Defaults to ~/.plectron/projects/<project>/runs.
    .PARAMETER HistoryLimit
    Number of runs to keep; older runs are pruned at startup.
    .PARAMETER NoBrowser
    Do not open a browser.
    .PARAMETER PassThru
    Return immediately with the server object instead of blocking until Ctrl+C.
    .EXAMPLE
    Start-Plectron
    .EXAMPLE
    Start-Plectron -Module ./src/MyTools.psd1
    .EXAMPLE
    Start-Plectron -Path ./scripts
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Path,
        [string[]]$Module,
        [string]$Config,
        [object[]]$Command,
        [string[]]$Page,
        [string]$Title,
        [ValidateRange(0, 65535)][int]$Port = 0,
        [string]$Engine,
        [string]$HistoryPath,
        [ValidateRange(1, 100000)][int]$HistoryLimit = 200,
        [switch]$NoBrowser,
        [switch]$PassThru,
        # Used by Show-PlxPage: open straight on the one page.
        [Parameter(DontShow)][switch]$Single
    )
    if ($Path -and -not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Folder '$Path' does not exist." }
    if ($Engine) { $null = Resolve-PlxEngine -Preferred $Engine }

    $project = Resolve-PlxProject -Path $Path -Module $Module -Config $Config -Command $Command -Page $Page -Title $Title
    if ($Single) { $project.Single = $true }
    $state = New-PlxState -Project $project -HistoryRoot $HistoryPath -Engine $Engine -HistoryLimit $HistoryLimit
    Limit-PlxHistory -HistoryRoot $state.HistoryRoot -Keep $HistoryLimit
    if ($Port -eq 0) { $Port = Get-PlxFreePort }
    $state.Port = $Port
    $state.Token = New-PlxToken
    $state.Stopping = $false

    # Discover up front: warms the module cache and surfaces load errors early.
    $tools = @(Get-PlxCatalog -State $state)
    $pages = @(Get-PlxPages -State $state)
    $handles = Start-PlxServer -State $state
    $url = "http://localhost:$Port/?t=$($state.Token)"
    if ($project.Single -and $tools.Count -eq 1 -and $pages.Count -eq 0) { $url += "#/tool/$($tools[0].id)" }
    if ($project.Single -and $pages.Count -eq 1 -and $tools.Count -eq 0) { $url += "#/page/$($pages[0].id)" }
    $server = [pscustomobject]@{
        PSTypeName = 'Plectron.Server'
        Url = $url; Port = $Port; Root = $state.Root; Title = $project.Title; Token = $state.Token
        State = $state; Handles = $handles
    }
    $script:PlxServers.Add($server)

    foreach ($t in $tools) { if ($t.parseError) { Write-Warning "$($t.title): $($t.parseError)" } }
    if (-not $NoBrowser) { Open-PlxBrowser -Url $url }
    if ($PassThru) { return $server }

    Write-Host "$($project.Title) is serving $($tools.Count) tool(s) and $($pages.Count) page(s) from $($state.Root)"
    Write-Host "Open $url" -ForegroundColor Cyan
    Write-Host 'Press Ctrl+C to stop.'
    try {
        while (-not $handles.Handle.IsCompleted) { Start-Sleep -Milliseconds 250 }
    } finally {
        Stop-Plectron -Server $server
    }
}

function Show-Plectron {
    <#
    .SYNOPSIS
    Open a web form for one or more module commands, like a friendlier Show-Command.
    .DESCRIPTION
    Accepts command names or Get-Command output from the pipeline. Commands
    must come from a module, since each run imports that module in a fresh
    PowerShell process.
    .EXAMPLE
    Show-Plectron Invoke-Deploy
    .EXAMPLE
    Get-Command -Module MyTools | Show-Plectron -Title 'My tools'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)][object[]]$Command,
        [string]$Title,
        [ValidateRange(0, 65535)][int]$Port = 0,
        [string]$Engine,
        [string]$HistoryPath,
        [switch]$NoBrowser,
        [switch]$PassThru
    )
    begin { $all = New-Object System.Collections.Generic.List[object] }
    process { foreach ($c in $Command) { $all.Add($c) } }
    end {
        $options = @{}
        foreach ($k in $PSBoundParameters.Keys) { if ($k -ne 'Command') { $options[$k] = $PSBoundParameters[$k] } }
        Start-Plectron -Command $all.ToArray() @options
    }
}

function Show-PlxPage {
    <#
    .SYNOPSIS
    Open an ad-hoc custom page, defined right here, in the browser.
    .DESCRIPTION
    The scriptblock must output a New-PlxPage. It runs in its own page process,
    so variables from this console are not available inside it.
    .EXAMPLE
    Show-PlxPage { New-PlxPage -Title 'Disks' { New-PlxTable -Name Drives -ScriptBlock { Get-PSDrive -PSProvider FileSystem } } }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][scriptblock]$Content,
        [string]$Title = 'Page',
        [ValidateRange(0, 65535)][int]$Port = 0,
        [string]$Engine,
        [string]$HistoryPath,
        [switch]$NoBrowser,
        [switch]$PassThru
    )
    $dir = Join-Path ([IO.Path]::GetTempPath()) "plectron-page-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $null = New-Item -ItemType Directory -Path $dir
    $file = Join-Path $dir ((ConvertTo-PlxSlug $Title) + '.ps1')
    [IO.File]::WriteAllText($file, $Content.ToString(), (New-Object System.Text.UTF8Encoding $false))
    $options = @{}
    foreach ($k in $PSBoundParameters.Keys) { if ($k -ne 'Content') { $options[$k] = $PSBoundParameters[$k] } }
    Start-Plectron -Page $file -Single @options
}

function Open-PlxBrowser {
    param([string]$Url)
    try {
        if (Test-PlxWindows) { Start-Process $Url }
        elseif ($IsMacOS) { & open $Url }
        else { & xdg-open $Url 2>&1 | Out-Null }
    } catch {
        Write-Warning "Could not open a browser: $($_.Exception.Message)"
    }
}
