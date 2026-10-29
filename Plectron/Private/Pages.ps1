# Custom pages: discovery, and one page process (RunHost/PageHost.ps1) per open
# page. Requests go to the process's stdin; its events are copied into a
# session events file that the browser follows over SSE.

function Get-PlxPageInfo {
    param([Parameter(Mandatory)][IO.FileInfo]$File)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$tokens, [ref]$errors)
    $description = $null
    $help = $ast.GetHelpContent()
    if ($help -and $help.Synopsis) { $description = $help.Synopsis.Trim() }
    # "TaskManager" -> "Task Manager": the real title comes from New-PlxPage once the page loads.
    $title = ($File.BaseName -creplace '(?<=[a-z0-9])(?=[A-Z])', ' ') -replace '[-_]+', ' '
    return [ordered]@{ id = (ConvertTo-PlxSlug $File.BaseName); title = $title; description = $description; path = $File.FullName }
}

function Get-PlxPages {
    param([Parameter(Mandatory)][hashtable]$State)
    $files = New-Object System.Collections.Generic.List[IO.FileInfo]
    foreach ($dir in $State.Project.Pages) { foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | Sort-Object Name) { $files.Add($f) } }
    foreach ($p in $State.Project.PageFiles) { $files.Add((Get-Item -LiteralPath $p)) }
    $seen = @{}
    foreach ($f in $files) {
        $info = Get-PlxPageInfo -File $f
        if ($seen.ContainsKey($info.id)) { continue }
        $seen[$info.id] = $true
        $info
    }
}

function Find-PlxPage {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Id)
    foreach ($p in @(Get-PlxPages -State $State)) { if ($p.id -eq $Id) { return $p } }
    return $null
}

function Test-PlxInPageFolder {
    param($Project, [string]$Path)
    foreach ($dir in $Project.Pages) {
        if ($Path.StartsWith($dir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Start-PlxPageSession {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)]$Page)
    $id = (New-PlxToken).Substring(0, 16)
    $dir = Join-Path $State.SessionRoot $id
    $null = New-Item -ItemType Directory -Path $dir -Force
    $jobPath = Join-Path ([IO.Path]::GetTempPath()) "plectron-$([guid]::NewGuid().ToString('N')).json"
    Write-PlxPrivateFile -Path $jobPath -Content (ConvertTo-PlxJson @{
            pagePath = $Page.path; root = $State.Root; setup = $State.Project.Setup; modules = @($State.Project.Modules)
        })
    $engine = Resolve-PlxEngine -Preferred $State.Engine
    $pageHost = Join-Path (Split-Path $State.RunHostPath) 'PageHost.ps1'
    $child = Start-PlxChildProcess -Exe $engine -Arguments (Get-PlxHostArguments -Script $pageHost -JobPath $jobPath) -WorkingDirectory $State.Root

    $entry = [hashtable]::Synchronized(@{
            Id = $id; PageId = $Page.id; Dir = $dir; Process = $child.Process; Stdin = $child.Stdin
            Done = $false; Clients = 0; LastSeen = [DateTime]::UtcNow; PowerShell = $null; Handle = $null
        })
    $State.Sessions[$id] = $entry

    $rs = [runspacefactory]::CreateRunspace((New-PlxSessionState -State $State))
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddCommand('Invoke-PlxSessionPump').AddParameters(@{ Entry = $entry; JobPath = $jobPath })
    $entry.PowerShell = $ps
    $entry.Handle = $ps.BeginInvoke()
    return $entry
}

# Runs in a background runspace for the lifetime of one page process.
function Invoke-PlxSessionPump {
    param($Entry, [string]$JobPath)
    $writer = Open-PlxEventWriter -Path (Join-Path $Entry.Dir 'events.ndjson')
    try {
        $null = Copy-PlxChildEvents -Process $Entry.Process -Writer $writer
        Add-PlxEventLine $writer 'end' @{ exitCode = $Entry.Process.ExitCode }
    } finally {
        $writer.Dispose()
        if (Test-Path -LiteralPath $JobPath) { Remove-Item -LiteralPath $JobPath -Force -ErrorAction SilentlyContinue }
        $Entry.Done = $true
    }
}

function Send-PlxPageRequest {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][hashtable]$Request)
    if ($Entry.Done -or $Entry.Process.HasExited) { throw 'The page process has stopped. Reload the page.' }
    $line = ConvertTo-PlxJson $Request
    [System.Threading.Monitor]::Enter($Entry.Stdin)
    try { $Entry.Stdin.WriteLine($line) } finally { [System.Threading.Monitor]::Exit($Entry.Stdin) }
}

function Stop-PlxPageSession {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Id)
    $entry = $State.Sessions[$Id]
    if (-not $entry) { return $false }
    $State.Sessions.Remove($Id)
    # Closing stdin lets the page host exit by itself; kill it if it doesn't.
    try { $entry.Stdin.Close() } catch { $null = $_ }
    try { if (-not $entry.Process.WaitForExit(2000)) { Stop-PlxProcessTree -Process $entry.Process } } catch { $null = $_ }
    if ($entry.Handle) { $null = $entry.Handle.AsyncWaitHandle.WaitOne(5000) }
    if ($entry.PowerShell) {
        $rs = $entry.PowerShell.Runspace
        $entry.PowerShell.Dispose()
        if ($rs) { $rs.Dispose() }
    }
    # Keep the events file briefly so a connected browser can read the final 'end'.
    $State.ClosedSessions[$Id] = @{ Dir = $entry.Dir; At = [DateTime]::UtcNow }
    return $true
}

# Called about once a second by the dispatcher.
function Remove-PlxIdleSessions {
    param([Parameter(Mandatory)][hashtable]$State)
    $now = [DateTime]::UtcNow
    foreach ($id in @($State.Sessions.Keys)) {
        $e = $State.Sessions[$id]
        if (-not $e) { continue }
        if ($e.Clients -le 0 -and ($now - $e.LastSeen).TotalSeconds -gt $State.SessionIdleSeconds) { $null = Stop-PlxPageSession -State $State -Id $id }
    }
    foreach ($id in @($State.ClosedSessions.Keys)) {
        $c = $State.ClosedSessions[$id]
        if (($now - $c.At).TotalSeconds -gt 30) {
            $State.ClosedSessions.Remove($id)
            Remove-Item -LiteralPath $c.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
