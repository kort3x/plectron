# Turns PowerShell stream records into protocol events. Shared by RunHost
# (one tool run) and PageHost (actions on a custom page).

# Classify one record from a *>&1-merged pipeline. Returns @{ t; data; extra; fatal }.
function ConvertTo-PlxStreamEvent {
    param([AllowNull()]$Item)
    $base = $Item
    if ($Item -is [System.Management.Automation.PSObject]) { $base = $Item.PSObject.BaseObject }

    if ($null -ne $Item -and @($Item.PSObject.TypeNames) -contains 'Plx.Event') {
        return @{ t = $Item.t; data = $Item.data; extra = $null; fatal = $null }
    }
    if ($base -is [System.Management.Automation.ErrorRecord]) {
        $isBinding = $base.Exception -is [System.Management.Automation.ParameterBindingException]
        $fatal = $null
        if ($isBinding) { $fatal = $base.Exception.Message }
        return @{ t = 'error'; data = (ConvertTo-PlxErrorData $base $isBinding); extra = $null; fatal = $fatal }
    }
    if ($base -is [System.Management.Automation.WarningRecord]) { return @{ t = 'warning'; data = $base.Message; extra = $null; fatal = $null } }
    if ($base -is [System.Management.Automation.VerboseRecord]) { return @{ t = 'verbose'; data = $base.Message; extra = $null; fatal = $null } }
    if ($base -is [System.Management.Automation.DebugRecord]) { return @{ t = 'debug'; data = $base.Message; extra = $null; fatal = $null } }
    if ($base -is [System.Management.Automation.InformationRecord]) {
        if (@($base.Tags) -contains 'PlxMessage') {
            return @{ t = 'message'; data = @{ text = [string]$base.MessageData.text; level = [string]$base.MessageData.level }; extra = $null; fatal = $null }
        }
        $data = [ordered]@{ message = [string]$base.MessageData; tags = @($base.Tags); host = $false; fg = $null; bg = $null }
        if ($base.MessageData -is [System.Management.Automation.HostInformationMessage]) {
            $data.host = $true
            $data.message = $base.MessageData.Message
            if ($null -ne $base.MessageData.ForegroundColor) { $data.fg = [string]$base.MessageData.ForegroundColor }
            if ($null -ne $base.MessageData.BackgroundColor) { $data.bg = [string]$base.MessageData.BackgroundColor }
        }
        return @{ t = 'info'; data = $data; extra = $null; fatal = $null }
    }

    $typeName = $null
    $display = $null
    if ($null -ne $Item) {
        $typeName = @($Item.PSObject.TypeNames)[0]
        $standard = $Item.PSObject.Members['PSStandardMembers']
        if ($standard -and $standard.Value.DefaultDisplayPropertySet) {
            $display = @($standard.Value.DefaultDisplayPropertySet.ReferencedPropertyNames)
        }
    }
    $value = $null
    try { $value = ConvertTo-PlxValue $Item } catch { $value = ($Item | Out-String).Trim() }
    return @{ t = 'output'; data = $value; extra = @{ type = $typeName; display = $display }; fatal = $null }
}

function ConvertTo-PlxProgressData {
    param($Record)
    return [ordered]@{
        id = $Record.ActivityId; parentId = $Record.ParentActivityId; activity = $Record.Activity
        status = $Record.StatusDescription; operation = $Record.CurrentOperation
        percent = $Record.PercentComplete; secondsRemaining = $Record.SecondsRemaining
        completed = ($Record.RecordType -eq [System.Management.Automation.ProgressRecordType]::Completed)
    }
}

# Writes everything collected so far as events. Returns the first fatal message, if any.
function Send-PlxStreams {
    param($PowerShell, $Output, [hashtable]$Extra)
    $fatal = $null
    $items = @($Output.ReadAll()) + @($PowerShell.Streams.Error.ReadAll())
    foreach ($item in $items) {
        $e = ConvertTo-PlxStreamEvent $item
        $merged = @{}
        if ($e.extra) { foreach ($k in $e.extra.Keys) { $merged[$k] = $e.extra[$k] } }
        if ($Extra) { foreach ($k in $Extra.Keys) { $merged[$k] = $Extra[$k] } }
        Write-PlxEvent $e.t $e.data $merged
        if ($e.fatal -and -not $fatal) { $fatal = $e.fatal }
    }
    foreach ($p in $PowerShell.Streams.Progress.ReadAll()) { Write-PlxEvent 'progress' (ConvertTo-PlxProgressData $p) $Extra }
    return $fatal
}

# Runs the commands queued on $PowerShell, streaming events while it runs.
# OnTick runs between polls (PageHost uses it to watch for cancel requests).
# Returns @{ status = 'succeeded'|'failed'|'cancelled'; error }.
function Invoke-PlxStreamed {
    param([Parameter(Mandatory)]$PowerShell, [hashtable]$Extra, [scriptblock]$OnTick)
    $output = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $inputData = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $inputData.Complete()
    $fatal = $null
    $handle = $PowerShell.BeginInvoke($inputData, $output)
    while (-not $handle.IsCompleted) {
        $f = Send-PlxStreams -PowerShell $PowerShell -Output $output -Extra $Extra
        if ($f -and -not $fatal) { $fatal = $f }
        if ($OnTick) { & $OnTick }
        Start-Sleep -Milliseconds 25
    }
    try { $PowerShell.EndInvoke($handle) } catch { $null = $_ }
    $f = Send-PlxStreams -PowerShell $PowerShell -Output $output -Extra $Extra
    if ($f -and -not $fatal) { $fatal = $f }

    $state = $PowerShell.InvocationStateInfo
    if ($state.State -eq [System.Management.Automation.PSInvocationState]::Stopped) { return @{ status = 'cancelled'; error = $null } }
    if ($state.State -eq [System.Management.Automation.PSInvocationState]::Failed) {
        $reason = $state.Reason
        $record = $null
        if ($reason -is [System.Management.Automation.IContainsErrorRecord]) { $record = $reason.ErrorRecord }
        if ($record) { Write-PlxEvent 'error' (ConvertTo-PlxErrorData $record $true) $Extra }
        else { Write-PlxEvent 'error' ([ordered]@{ message = $reason.Message; terminating = $true }) $Extra }
        return @{ status = 'failed'; error = $reason.Message }
    }
    if ($fatal) { return @{ status = 'failed'; error = $fatal } }
    return @{ status = 'succeeded'; error = $null }
}
