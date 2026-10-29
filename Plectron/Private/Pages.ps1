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
    try {
        $engine = Resolve-PlxEngine -Preferred $State.Engine
        $pageHost = Join-Path (Split-Path $State.RunHostPath) 'PageHost.ps1'
        $child = Start-PlxChildProcess -Exe $engine -Arguments (Get-PlxHostArguments -Script $pageHost -JobPath $jobPath) -WorkingDirectory $State.Root
    } catch {
        Remove-Item -LiteralPath $jobPath, $dir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }

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

# Action ids on the page, read once from the layout event the page host sent.
function Get-PlxSessionHandlers {
    param([Parameter(Mandatory)]$Entry)
    if ($Entry.Handlers) { return $Entry.Handlers }
    $file = Join-Path $Entry.Dir 'events.ndjson'
    $chunk = Read-PlxEventChunk -Path $file -Offset 0
    foreach ($line in $chunk.Lines) {
        if (-not $line.StartsWith('{"t":"layout"')) { continue }
        $ids = New-Object System.Collections.Generic.List[string]
        $walk = { param($n) if ($n.handler) { $ids.Add([string]$n.handler) }; foreach ($c in $n.children) { & $walk $c } }
        & $walk (ConvertFrom-PlxJson $line).data
        $Entry.Handlers = $ids.ToArray()
        return $Entry.Handlers
    }
    return @()
}

function Send-PlxPageRequest {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][hashtable]$Request)
    if ($Entry.Done -or $Entry.Process.HasExited) { throw 'The page process has stopped. Reload the page.' }
    $line = ConvertTo-PlxJson $Request
    [System.Threading.Monitor]::Enter($Entry.Stdin)
    try { $Entry.Stdin.WriteLine($line) } finally { [System.Threading.Monitor]::Exit($Entry.Stdin) }
}

# Never blocks: the process is killed right away and the pump runspace is
# disposed by Remove-PlxIdleSessions once it has written the final 'end' event.
function Stop-PlxPageSession {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Id)
    $entry = $null
    [System.Threading.Monitor]::Enter($State.Sessions.SyncRoot)
    try {
        $entry = $State.Sessions[$Id]
        if ($entry) { $State.Sessions.Remove($Id) }
    } finally { [System.Threading.Monitor]::Exit($State.Sessions.SyncRoot) }
    if (-not $entry) { return $false }
    [System.Threading.Monitor]::Enter($entry.Stdin)
    try { $entry.Stdin.Close() } catch { $null = $_ } finally { [System.Threading.Monitor]::Exit($entry.Stdin) }
    try { Stop-PlxProcessTree -Process $entry.Process } catch { $null = $_ }
    # Keep the events file briefly so a connected browser can read the final 'end'.
    $State.ClosedSessions[$Id] = @{ Entry = $entry; At = [DateTime]::UtcNow }
    return $true
}

function Close-PlxSessionPump {
    param($Entry)
    if (-not $Entry.PowerShell) { return }
    $rs = $Entry.PowerShell.Runspace
    $Entry.PowerShell.Dispose()
    if ($rs) { $rs.Dispose() }
    $Entry.PowerShell = $null
}

# Thread-safe change of a session's connected-client count.
function Update-PlxSessionClients {
    param($Entry, [int]$Delta)
    [System.Threading.Monitor]::Enter($Entry.SyncRoot)
    try { $Entry.Clients += $Delta; $Entry.LastSeen = [DateTime]::UtcNow }
    finally { [System.Threading.Monitor]::Exit($Entry.SyncRoot) }
}

# Called about once a second by the dispatcher.
function Remove-PlxIdleSessions {
    param([Parameter(Mandatory)][hashtable]$State)
    $now = [DateTime]::UtcNow
    foreach ($id in @($State.Sessions.Keys)) {
        $session = $State.Sessions[$id]
        if (-not $session) { continue }
        $idle = $session.Clients -le 0 -and ($now - $session.LastSeen).TotalSeconds -gt $State.SessionIdleSeconds
        if ($idle -or $session.Done) { $null = Stop-PlxPageSession -State $State -Id $id }
    }
    foreach ($id in @($State.ClosedSessions.Keys)) {
        $closed = $State.ClosedSessions[$id]
        if ($closed.Entry.Done) { Close-PlxSessionPump -Entry $closed.Entry }
        if (($now - $closed.At).TotalSeconds -gt 30) {
            $State.ClosedSessions.Remove($id)
            Close-PlxSessionPump -Entry $closed.Entry
            Remove-Item -LiteralPath $closed.Entry.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
