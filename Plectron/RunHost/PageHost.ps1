# Child-side host for one open custom page. Loads the page script into a
# persistent runspace (so real objects and variables survive between clicks),
# then serves requests read from stdin, one JSON line each:
#   { id, type = 'refresh'|'invoke', handler, names, inputs, selections }
#   { type = 'cancel', id }   (stops that request, or drops it if still queued;
#                              without an id, stops whatever is running)
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
# One thread for the page's lifetime, so COM/STA objects created by the page keep working.
$runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
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
    . $__plxJob.setup *>&1 | Where-Object { Test-PlxStreamRecord $_ }
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
$script:current = $null
$script:stopCurrent = $false

function Receive-PlxRequests {
    while (-not $script:eof -and $script:pending.IsCompleted) {
        $line = $null
        try { $line = $script:pending.Result } catch { $line = $null }  # a failed read means stdin is gone
        if ($null -eq $line) { $script:eof = $true; break }
        $script:pending = $stdin.ReadLineAsync()
        if (-not $line.Trim()) { continue }
        $request = ConvertFrom-PlxJson $line
        if ($request.type -eq 'cancel') { Receive-PlxCancel $request }
        else { $script:queue.Enqueue($request) }
    }
}

function Receive-PlxCancel($cancel) {
    if (-not $cancel.id -or $cancel.id -eq $script:current) { $script:stopCurrent = $true; return }
    # Drop a queued request and report it as cancelled.
    $kept = @($script:queue.ToArray() | Where-Object { $_.id -ne $cancel.id })
    if ($kept.Count -eq $script:queue.Count) { return }
    $script:queue.Clear()
    foreach ($r in $kept) { $script:queue.Enqueue($r) }
    Write-PlxEvent 'done' @{ status = 'cancelled'; error = $null } @{ req = $cancel.id }
}

$watchCancel = {
    Receive-PlxRequests
    if ($script:stopCurrent) {
        $script:stopCurrent = $false
        $null = $ps.BeginStop($null, $null)
    }
}

$null = $ps.AddScript($init).AddArgument($job).AddArgument((Join-Path $PSScriptRoot '../Private')).AddArgument((Join-Path $PSScriptRoot '../Public'))
try {
    $script:current = 'load'
    $result = Invoke-PlxStreamed -PowerShell $ps -Extra @{ req = 'load' } -OnTick $watchCancel
    Write-PlxEvent 'done' @{ status = $result.status; error = $result.error } @{ req = 'load' }
    if ($result.status -ne 'succeeded') { exit 1 }

    while ($true) {
        $script:current = $null
        Receive-PlxRequests
        $script:stopCurrent = $false  # nothing is running, so there is nothing to stop
        if ($script:queue.Count -gt 0) {
            $request = $script:queue.Dequeue()
            $script:current = $request.id
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
} finally {
    $ps.Dispose()
    $runspace.Dispose()
}
