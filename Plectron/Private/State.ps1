# Shared server state. A synchronized hashtable so request handlers and run
# pumps in other runspaces can read and update it safely.

function New-PlxState {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$HistoryRoot,
        [string]$Engine,
        [int]$HistoryLimit = 200
    )
    if (-not $HistoryRoot) { $HistoryRoot = Join-Path (Join-Path $HOME '.plectron') 'runs' }
    if (-not (Test-Path -LiteralPath $HistoryRoot)) { $null = New-Item -ItemType Directory -Path $HistoryRoot -Force }
    $moduleRoot = Split-Path $PSScriptRoot
    return [hashtable]::Synchronized(@{
            Root = (Resolve-Path -LiteralPath $Root).Path
            HistoryRoot = (Resolve-Path -LiteralPath $HistoryRoot).Path
            HistoryLimit = $HistoryLimit
            Engine = $Engine
            Runs = [hashtable]::Synchronized(@{})
            ToolCache = [hashtable]::Synchronized(@{})
            CorePath = Join-Path $PSScriptRoot 'Plectron.Core.psm1'
            RunHostPath = Join-Path (Join-Path $moduleRoot 'RunHost') 'RunHost.ps1'
            WwwRoot = Join-Path $moduleRoot 'www'
            Token = $null
            Port = $null
        })
}

function Test-PlxWindows { return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT }

# Session state for background runspaces: the same private functions as here.
function New-PlxSessionState {
    param([Parameter(Mandatory)][hashtable]$State)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    if (Test-PlxWindows) { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass }
    $iss.ImportPSModule([string[]]@($State.CorePath))
    return $iss
}
