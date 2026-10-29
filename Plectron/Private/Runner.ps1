# Starting, tracking and cancelling runs. Each run is a child PowerShell
# process (RunHost.ps1) pumped by a background runspace into events.ndjson.

function Resolve-PlxEngine {
    param([string]$Preferred, [switch]$RequiresDesktop)
    if ($RequiresDesktop -and (Test-PlxWindows)) {
        $c = Get-Command 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return $c.Path }
    }
    if ($Preferred) {
        if (Test-Path -LiteralPath $Preferred -PathType Leaf) { return (Resolve-Path -LiteralPath $Preferred).Path }
        $c = Get-Command $Preferred -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return $c.Path }
        throw "PowerShell engine '$Preferred' was not found."
    }
    if ($PSVersionTable.PSEdition -eq 'Core') { return [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
    foreach ($name in 'pwsh', 'powershell') {
        $c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return $c.Path }
    }
    throw 'No PowerShell engine found.'
}

# Split submitted form values into plain parameters, secrets (sent to the
# child out of band) and a redacted copy for the history.
function ConvertTo-PlxJob {
    param([Parameter(Mandatory)]$Tool, [hashtable]$Values)
    $job = @{ parameters = @{}; secure = @{}; redacted = [ordered]@{} }
    if (-not $Values) { return $job }
    foreach ($name in $Values.Keys) {
        $def = $Tool.parameters | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if (-not $def) { throw "Unknown parameter '$name' for tool '$($Tool.id)'." }
        $v = $Values[$name]
        if ($null -eq $v) { continue }
        if ($v -is [string] -and $v -eq '') { continue }
        if ($v -is [array] -and $v.Count -eq 0) { continue }
        if ($def.type -eq 'switch' -and -not [bool]$v) { continue }

        # The declared type decides how a value is passed; a 'password' widget
        # on a plain string only masks it in the UI and history.
        if ($def.type -eq 'securestring') {
            $job.secure[$name] = @{ kind = 'securestring'; password = [string]$v }
            $job.redacted[$name] = '***'
        } elseif ($def.type -eq 'pscredential') {
            if ($v -isnot [hashtable] -or -not $v.user) { continue }
            $job.secure[$name] = @{ kind = 'credential'; user = [string]$v.user; password = [string]$v.password }
            $job.redacted[$name] = @{ user = [string]$v.user; password = '***' }
        } elseif ($def.widget -eq 'password') {
            $job.parameters[$name] = $v
            $job.redacted[$name] = '***'
        } else {
            $job.parameters[$name] = $v
            $job.redacted[$name] = $v
        }
    }
    return $job
}

function Write-PlxPrivateFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    [IO.File]::WriteAllText($Path, '')
    if (-not (Test-PlxWindows)) {
        # UnixFileMode only exists on .NET 7+ (pwsh 7.4+); older engines use chmod.
        $modeType = 'System.IO.UnixFileMode' -as [type]
        if ($modeType) { [IO.File]::SetUnixFileMode($Path, [Enum]::Parse($modeType, 'UserRead, UserWrite')) }
        else { & chmod 600 $Path }
    }
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

function Clear-PlxFinishedRuns {
    param([Parameter(Mandatory)][hashtable]$State)
    foreach ($id in @($State.Runs.Keys)) {
        $e = $State.Runs[$id]
        if ($e.Done -and $e.PowerShell) {
            try { $e.PowerShell.EndInvoke($e.Handle) } catch { $null = $_ }
            $rs = $e.PowerShell.Runspace
            $e.PowerShell.Dispose()
            if ($rs) { $rs.Dispose() }
            $e.PowerShell = $null
        }
    }
}

function Start-PlxRun {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)]$Tool, [hashtable]$Values)
    if ($Tool.parseError) { throw "Tool '$($Tool.id)' cannot run: $($Tool.parseError)" }
    Clear-PlxFinishedRuns -State $State

    $job = ConvertTo-PlxJob -Tool $Tool -Values $Values
    $engine = Resolve-PlxEngine -Preferred $State.Engine -RequiresDesktop:([bool]$Tool.requiresDesktop)
    $id = New-PlxRunId
    $dir = Get-PlxRunDir -HistoryRoot $State.HistoryRoot -Id $id
    $null = New-Item -ItemType Directory -Path $dir -Force

    $meta = [ordered]@{
        id = $id; toolId = $Tool.id; toolTitle = $Tool.title; toolPath = $Tool.path
        parameters = $job.redacted; engine = $engine
        startedAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        endedAt = $null; durationMs = $null; status = 'running'; exitCode = $null
    }
    Save-PlxRunMeta -Dir $dir -Meta $meta

    $jobPath = Join-Path ([IO.Path]::GetTempPath()) "plectron-$([guid]::NewGuid().ToString('N')).json"
    Write-PlxPrivateFile -Path $jobPath -Content (ConvertTo-PlxJson @{ scriptPath = $Tool.path; parameters = $job.parameters; secure = $job.secure })

    $policy = ''
    if (Test-PlxWindows) { $policy = '-ExecutionPolicy Bypass ' }
    $arguments = "-NoProfile -NonInteractive $policy-File `"$($State.RunHostPath)`" -JobPath `"$jobPath`""

    $entry = [hashtable]::Synchronized(@{ Done = $false; Cancelled = $false; Process = $null; Status = 'running'; PowerShell = $null; Handle = $null })
    $State.Runs[$id] = $entry

    $rs = [runspacefactory]::CreateRunspace((New-PlxSessionState -State $State))
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddCommand('Invoke-PlxRunPump').AddParameters(@{
            Entry = $entry; RunDir = $dir; Exe = $engine; Arguments = $arguments
            JobPath = $jobPath; WorkingDirectory = (Split-Path $Tool.path)
        })
    $entry.PowerShell = $ps
    $entry.Handle = $ps.BeginInvoke()
    return $meta
}

function Add-PlxEventLine {
    param($Writer, [string]$Type, $Data)
    $e = [ordered]@{ t = $Type; ts = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture); data = $Data }
    $Writer.WriteLine((ConvertTo-PlxJson $e))
}

# Runs in a background runspace for the lifetime of one child process.
function Invoke-PlxRunPump {
    param($Entry, [string]$RunDir, [string]$Exe, [string]$Arguments, [string]$JobPath, [string]$WorkingDirectory)

    $started = [DateTime]::UtcNow
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $fs = New-Object IO.FileStream ((Join-Path $RunDir 'events.ndjson'), [IO.FileMode]::Append, [IO.FileAccess]::Write, $share)
    $writer = New-Object IO.StreamWriter ($fs, (New-Object System.Text.UTF8Encoding $false))
    $writer.AutoFlush = $true
    $sentinel = Get-PlxSentinel
    $childExit = $null
    $exitCode = $null
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = $Arguments
        $psi.WorkingDirectory = $WorkingDirectory
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
        $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
        $proc = [Diagnostics.Process]::Start($psi)
        $Entry.Process = $proc
        $proc.StandardInput.Close()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        while ($null -ne ($line = $proc.StandardOutput.ReadLine())) {
            if ($line.StartsWith($sentinel)) {
                $json = $line.Substring($sentinel.Length)
                if ($json.StartsWith('{"t":"exit"')) { $childExit = (ConvertFrom-PlxJson $json).data }
                $writer.WriteLine($json)
            } else {
                Add-PlxEventLine $writer 'raw' $line
            }
        }
        $proc.WaitForExit()
        $stderr = $stderrTask.Result
        if ($stderr -and $stderr.Trim()) { Add-PlxEventLine $writer 'stderr' $stderr.TrimEnd() }
        $exitCode = $proc.ExitCode
    } catch {
        Add-PlxEventLine $writer 'error' @{ message = "Failed to run: $($_.Exception.Message)"; terminating = $true }
    } finally {
        if (Test-Path -LiteralPath $JobPath) { Remove-Item -LiteralPath $JobPath -Force -ErrorAction SilentlyContinue }
    }

    $status = 'failed'
    if ($Entry.Cancelled) { $status = 'cancelled' }
    elseif ($childExit) { $status = $childExit.status }
    $ended = [DateTime]::UtcNow
    $duration = [long]($ended - $started).TotalMilliseconds
    try {
        Add-PlxEventLine $writer 'end' ([ordered]@{ status = $status; exitCode = $exitCode; durationMs = $duration })
        $writer.Dispose()
        $meta = Read-PlxRunMeta -Dir $RunDir
        $meta.status = $status
        $meta.exitCode = $exitCode
        $meta.endedAt = $ended.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        $meta.durationMs = $duration
        Save-PlxRunMeta -Dir $RunDir -Meta $meta
    } finally {
        $Entry.Status = $status
        $Entry.Done = $true
    }
}

function Stop-PlxProcessTree {
    param([Diagnostics.Process]$Process)
    if (-not $Process -or $Process.HasExited) { return }
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        # .NET Framework cannot kill a process tree.
        & taskkill.exe /T /F /PID $Process.Id 2>&1 | Out-Null
    } else {
        $Process.Kill($true)
    }
}

function Stop-PlxRun {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Id)
    $entry = $State.Runs[$Id]
    if (-not $entry -or $entry.Done) { return $false }
    $entry.Cancelled = $true
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not $entry.Process -and -not $entry.Done -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    try { Stop-PlxProcessTree -Process $entry.Process } catch { $null = $_ }
    return $true
}

function Wait-PlxRun {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Id, [int]$TimeoutSec = 30)
    $entry = $State.Runs[$Id]
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ($entry -and -not $entry.Done -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    return Get-PlxRun -State $State -Id $Id
}
