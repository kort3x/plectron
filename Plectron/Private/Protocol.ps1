# Wire protocol between RunHost (child process) and the server: one event per
# stdout line, prefixed with a record-separator sentinel so stray console
# writes from scripts can be told apart.

function Get-PlxSentinel { return ([string][char]0x1E) + 'PLX ' }

function Write-PlxEvent {
    param([Parameter(Mandatory)][string]$Type, [AllowNull()]$Data, [hashtable]$Extra)
    $e = [ordered]@{ t = $Type; ts = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture); data = $Data }
    if ($Extra) { foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] } }
    [Console]::Out.WriteLine((Get-PlxSentinel) + (ConvertTo-PlxJson $e))
    [Console]::Out.Flush()
}

function ConvertFrom-PlxEventLine {
    param([AllowNull()][AllowEmptyString()][string]$Line)
    $s = Get-PlxSentinel
    if (-not $Line -or -not $Line.StartsWith($s)) { return $null }
    try { return ConvertFrom-PlxJson $Line.Substring($s.Length) } catch { return $null }
}

function ConvertTo-PlxErrorData {
    param([System.Management.Automation.ErrorRecord]$Record, [bool]$Terminating)
    $position = $null
    if ($Record.InvocationInfo) { $position = $Record.InvocationInfo.PositionMessage }
    return [ordered]@{
        message = $Record.Exception.Message
        category = $Record.CategoryInfo.ToString()
        errorId = $Record.FullyQualifiedErrorId
        position = $position
        scriptStack = $Record.ScriptStackTrace
        terminating = $Terminating
    }
}
