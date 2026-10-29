function Start-Plectron {
    <#
    .SYNOPSIS
    Serve a folder of PowerShell scripts as a local web UI.
    .DESCRIPTION
    Every .ps1 file under -Path becomes a tool with a form generated from its
    param() block. The server listens on localhost only and is protected by a
    per-session token embedded in the printed URL.
    .PARAMETER Path
    Folder containing the tool scripts. Defaults to the current directory.
    .PARAMETER Port
    Port to listen on. 0 (the default) picks a free port.
    .PARAMETER Engine
    PowerShell executable used to run tools (e.g. pwsh, powershell.exe or a full path).
    Defaults to the engine running Plectron.
    .PARAMETER HistoryPath
    Where run history is kept. Defaults to ~/.plectron/runs.
    .PARAMETER HistoryLimit
    Number of runs to keep; older runs are pruned at startup.
    .PARAMETER NoBrowser
    Do not open a browser.
    .PARAMETER PassThru
    Return immediately with the server object instead of blocking until Ctrl+C.
    .EXAMPLE
    Start-Plectron -Path ./tools
    #>
    [CmdletBinding()]
    param(
        [string]$Path = (Get-Location).Path,
        [ValidateRange(0, 65535)][int]$Port = 0,
        [string]$Engine,
        [string]$HistoryPath,
        [ValidateRange(1, 100000)][int]$HistoryLimit = 200,
        [switch]$NoBrowser,
        [switch]$PassThru
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Folder '$Path' does not exist." }
    if ($Engine) { $null = Resolve-PlxEngine -Preferred $Engine }

    $state = New-PlxState -Root $Path -HistoryRoot $HistoryPath -Engine $Engine -HistoryLimit $HistoryLimit
    Limit-PlxHistory -HistoryRoot $state.HistoryRoot -Keep $HistoryLimit
    if ($Port -eq 0) { $Port = Get-PlxFreePort }
    $state.Port = $Port
    $state.Token = New-PlxToken
    $state.Stopping = $false

    $handles = Start-PlxServer -State $state
    $url = "http://localhost:$Port/?t=$($state.Token)"
    $server = [pscustomobject]@{
        PSTypeName = 'Plectron.Server'
        Url = $url; Port = $Port; Root = $state.Root; Token = $state.Token
        State = $state; Handles = $handles
    }
    $script:PlxServers.Add($server)

    if (-not $NoBrowser) { Open-PlxBrowser -Url $url }
    if ($PassThru) { return $server }

    Write-Host "Plectron is serving $($state.Root)"
    Write-Host "Open $url" -ForegroundColor Cyan
    Write-Host 'Press Ctrl+C to stop.'
    try {
        while (-not $handles.Handle.IsCompleted) { Start-Sleep -Milliseconds 250 }
    } finally {
        Stop-Plectron -Server $server
    }
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
