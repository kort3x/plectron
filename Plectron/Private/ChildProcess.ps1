# Child PowerShell processes (RunHost, PageHost): start them and copy their
# protocol events into an events file.

function Get-PlxHostArguments {
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][string]$JobPath)
    $policy = ''
    if (Test-PlxWindows) { $policy = '-ExecutionPolicy Bypass ' }
    return "-NoProfile -NonInteractive $policy-File `"$Script`" -JobPath `"$JobPath`""
}

function Open-PlxEventWriter {
    param([Parameter(Mandatory)][string]$Path)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $fs = New-Object IO.FileStream ($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, $share)
    $writer = New-Object IO.StreamWriter ($fs, (New-Object System.Text.UTF8Encoding $false))
    $writer.AutoFlush = $true
    return $writer
}

function Add-PlxEventLine {
    param($Writer, [string]$Type, $Data)
    $e = [ordered]@{ t = $Type; ts = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture); data = $Data }
    $Writer.WriteLine((ConvertTo-PlxJson $e))
}

# Stdin stays open (page hosts read requests from it); callers that don't need it close it.
function Start-PlxChildProcess {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Arguments, [string]$WorkingDirectory)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Arguments
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $proc = [Diagnostics.Process]::Start($psi)
    # A UTF-8 writer without BOM for requests (StandardInput defaults to the console encoding).
    $stdin = New-Object IO.StreamWriter ($proc.StandardInput.BaseStream, $utf8)
    $stdin.AutoFlush = $true
    return @{ Process = $proc; Stdin = $stdin }
}

# Copies protocol lines to the events file until the child exits; other stdout
# lines become 'raw' events and stderr a final 'stderr' event. Returns the
# data of the child's 'exit' event, if it sent one.
function Copy-PlxChildEvents {
    param([Parameter(Mandatory)]$Process, [Parameter(Mandatory)]$Writer)
    $sentinel = Get-PlxSentinel
    $childExit = $null
    $stderrTask = $Process.StandardError.ReadToEndAsync()
    while ($null -ne ($line = $Process.StandardOutput.ReadLine())) {
        if ($line.StartsWith($sentinel)) {
            $json = $line.Substring($sentinel.Length)
            if ($json.StartsWith('{"t":"exit"')) { $childExit = (ConvertFrom-PlxJson $json).data }
            $Writer.WriteLine($json)
        } else {
            Add-PlxEventLine $Writer 'raw' $line
        }
    }
    $Process.WaitForExit()
    $stderr = $stderrTask.Result
    if ($stderr -and $stderr.Trim()) { Add-PlxEventLine $Writer 'stderr' $stderr.TrimEnd() }
    return $childExit
}
