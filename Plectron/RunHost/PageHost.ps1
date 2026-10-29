# Child-side host for one open custom page. Loads the page script into a
# persistent runspace (so real objects and variables survive between clicks),
# then serves requests read from stdin, one JSON line each:
#   { id, type = 'refresh'|'invoke', handler, names, inputs, selections } or { type = 'cancel' }
# Every event is tagged with the request id; each request ends with a 'done'
# event. Must stay 5.1-compatible.
param([Parameter(Mandatory)][string]$JobPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Private/Compat.ps1')
. (Join-Path $PSScriptRoot '../Private/Protocol.ps1')
. (Join-Path $PSScriptRoot '../Private/Streams.ps1')
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$job = ConvertFrom-PlxJson (Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8)
Remove-Item -LiteralPath $JobPath -Force

$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$ps = [powershell]::Create()
$ps.Runspace = $runspace

# AddScript runs at global scope, so the helpers, the page script's variables
# and its scriptblocks all live in the runspace for the page's lifetime.
$init = @'
param($__plxJob, $__plxPrivate, $__plxPublic)
. (Join-Path $__plxPrivate 'Compat.ps1')
. (Join-Path $__plxPrivate 'PageModel.ps1')
. (Join-Path $__plxPublic 'Page.ps1')
if ($__plxJob.root) { Set-Location -LiteralPath $__plxJob.root }
if ($__plxJob.setup) {
    . $__plxJob.setup *>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or $_ -is [System.Management.Automation.WarningRecord] -or
        $_ -is [System.Management.Automation.InformationRecord] }
}
foreach ($__plxModule in @($__plxJob.modules)) { if ($__plxModule) { Import-Module $__plxModule -ErrorAction Stop } }
$__plxNodes = @(. $__plxJob.pagePath) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['plx'] -eq 'node' }
$global:__plxPage = Register-PlxPage ($__plxNodes | Select-Object -Last 1)
Invoke-PlxPageRequest @{ type = 'load' }
'@

$stdin = New-Object IO.StreamReader ([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding $false))
$script:pending = $stdin.ReadLineAsync()
$script:queue = New-Object System.Collections.Generic.Queue[object]
$script:eof = $false
$script:cancelRequested = $false

function Receive-PlxRequests {
    while (-not $script:eof -and $script:pending.IsCompleted) {
        $line = $script:pending.Result
        if ($null -eq $line) { $script:eof = $true; break }
        $script:pending = $stdin.ReadLineAsync()
        if (-not $line.Trim()) { continue }
        $request = ConvertFrom-PlxJson $line
        if ($request.type -eq 'cancel') { $script:cancelRequested = $true }
        else { $script:queue.Enqueue($request) }
    }
}

$watchCancel = {
    Receive-PlxRequests
    if ($script:cancelRequested) {
        $script:cancelRequested = $false
        $null = $ps.BeginStop($null, $null)
    }
}

$null = $ps.AddScript($init).AddArgument($job).AddArgument((Join-Path $PSScriptRoot '../Private')).AddArgument((Join-Path $PSScriptRoot '../Public'))
$result = Invoke-PlxStreamed -PowerShell $ps -Extra @{ req = 'load' }
Write-PlxEvent 'done' @{ status = $result.status; error = $result.error } @{ req = 'load' }
if ($result.status -ne 'succeeded') { exit 1 }

while ($true) {
    Receive-PlxRequests
    $script:cancelRequested = $false  # a cancel with nothing running is ignored
    if ($script:queue.Count -gt 0) {
        $request = $script:queue.Dequeue()
        $ps.Commands.Clear()
        $null = $ps.AddCommand('Invoke-PlxPageRequest').AddArgument($request)
        $result = Invoke-PlxStreamed -PowerShell $ps -Extra @{ req = $request.id } -OnTick $watchCancel
        Write-PlxEvent 'done' @{ status = $result.status; error = $result.error } @{ req = $request.id }
    } elseif ($script:eof) {
        break
    } else {
        Start-Sleep -Milliseconds 25
    }
}
$ps.Dispose()
$runspace.Dispose()
