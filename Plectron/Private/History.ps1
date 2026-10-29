# Run history on disk: <HistoryRoot>/<runId>/{meta.json,events.ndjson}.

function New-PlxRunId {
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 6)
    return (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + $suffix
}

function Get-PlxRunDir {
    param([Parameter(Mandatory)][string]$HistoryRoot, [Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^\d{8}-\d{6}-[0-9a-f]{6}$') { throw "Invalid run id '$Id'" }
    return Join-Path $HistoryRoot $Id
}

function Save-PlxRunMeta {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)]$Meta)
    $path = Join-Path $Dir 'meta.json'
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-PlxJson $Meta), (New-Object System.Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Read-PlxRunMeta {
    param([Parameter(Mandatory)][string]$Dir)
    $path = Join-Path $Dir 'meta.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return ConvertFrom-PlxJson ([IO.File]::ReadAllText($path)) } catch { return $null }
}

# Meta for one run; a 'running' run that this server is not tracking was left
# behind by a host that died, so report it as abandoned.
function Get-PlxRun {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Id)
    $dir = Get-PlxRunDir -HistoryRoot $State.HistoryRoot -Id $Id
    return Repair-PlxRunStatus -State $State -Meta (Read-PlxRunMeta -Dir $dir)
}

function Repair-PlxRunStatus {
    param([Parameter(Mandatory)][hashtable]$State, $Meta)
    if ($Meta -and $Meta.status -eq 'running' -and -not $State.Runs[$Meta.id]) { $Meta.status = 'abandoned' }
    return $Meta
}

function Get-PlxRuns {
    param([Parameter(Mandatory)][string]$HistoryRoot, [int]$Limit = 0)
    if (-not (Test-Path -LiteralPath $HistoryRoot)) { return }
    $metas = foreach ($d in Get-ChildItem -LiteralPath $HistoryRoot -Directory) {
        $m = Read-PlxRunMeta -Dir $d.FullName
        if ($m) { $m }
    }
    $sorted = @($metas | Sort-Object { [string]$_.startedAt } -Descending)
    if ($Limit -gt 0 -and $sorted.Count -gt $Limit) { $sorted = $sorted[0..($Limit - 1)] }
    return $sorted
}

function Remove-PlxRun {
    param([Parameter(Mandatory)][string]$HistoryRoot, [Parameter(Mandatory)][string]$Id)
    $dir = Get-PlxRunDir -HistoryRoot $HistoryRoot -Id $Id
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
}

function Limit-PlxHistory {
    param([Parameter(Mandatory)][string]$HistoryRoot, [Parameter(Mandatory)][int]$Keep)
    $runs = @(Get-PlxRuns -HistoryRoot $HistoryRoot)
    if ($runs.Count -le $Keep) { return }
    foreach ($r in $runs[$Keep..($runs.Count - 1)]) { Remove-PlxRun -HistoryRoot $HistoryRoot -Id $r.id }
}

# Read complete lines appended to an events file since Offset. Partial trailing
# lines are left for the next call. Splitting on the LF byte is UTF-8 safe.
function Read-PlxEventChunk {
    param([Parameter(Mandatory)][string]$Path, [long]$Offset = 0)
    $result = @{ Lines = @(); Offset = $Offset }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $fs = New-Object IO.FileStream ($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        if ($fs.Length -le $Offset) { return $result }
        $null = $fs.Seek($Offset, [IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] ($fs.Length - $Offset)
        $read = 0
        while ($read -lt $buffer.Length) {
            $n = $fs.Read($buffer, $read, $buffer.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $last = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
        if ($last -lt 0) { return $result }
        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $last)
        $result.Lines = @($text -split "`r?`n" | Where-Object { $_ })
        $result.Offset = $Offset + $last + 1
        return $result
    } finally { $fs.Dispose() }
}
