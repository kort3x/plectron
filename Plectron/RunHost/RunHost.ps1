# Child-side host. Runs one tool script inside a nested PowerShell instance and
# reports every stream as protocol events on stdout. Must stay 5.1-compatible.
param([Parameter(Mandatory)][string]$JobPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Private/Compat.ps1')
. (Join-Path $PSScriptRoot '../Private/Protocol.ps1')
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$job = ConvertFrom-PlxJson (Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8)
Remove-Item -LiteralPath $JobPath -Force

$arguments = @{}
if ($job.parameters) { foreach ($k in $job.parameters.Keys) { $arguments[$k] = $job.parameters[$k] } }
if ($job.secure) {
    foreach ($k in $job.secure.Keys) {
        $s = $job.secure[$k]
        $secure = New-Object System.Security.SecureString
        foreach ($c in ([string]$s.password).ToCharArray()) { $secure.AppendChar($c) }
        if ($s.kind -eq 'credential') { $arguments[$k] = New-Object System.Management.Automation.PSCredential ([string]$s.user, $secure) }
        else { $arguments[$k] = $secure }
    }
}

# *>&1 merges every stream except Progress into Output, preserving order.
# A job runs either a script file or an exported command of a module, after
# the project's optional setup script.
$runner = @'
param($__job, $__a)
$global:LASTEXITCODE = 0
if ($__job.setup) {
    # Keep the setup's warnings, errors and messages in the run; drop its plain output.
    . $__job.setup *>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or $_ -is [System.Management.Automation.WarningRecord] -or
        $_ -is [System.Management.Automation.VerboseRecord] -or $_ -is [System.Management.Automation.DebugRecord] -or $_ -is [System.Management.Automation.InformationRecord] }
}
if ($__job.kind -eq 'command') {
    $__m = Import-Module $__job.module -PassThru -ErrorAction Stop | Select-Object -First 1
    & (Get-Command -Module $__m.Name -Name $__job.command -ErrorAction Stop) @__a *>&1
} else {
    Set-Location -LiteralPath ([IO.Path]::GetDirectoryName($__job.scriptPath))
    & $__job.scriptPath @__a *>&1
}
'@
$ps = [powershell]::Create()
$null = $ps.AddScript($runner).AddArgument($job).AddArgument($arguments)
$output = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
$inputData = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
$inputData.Complete()

$script:fatal = $null

function Send-Record($item) {
    $base = $item
    if ($item -is [System.Management.Automation.PSObject]) { $base = $item.PSObject.BaseObject }
    if ($base -is [System.Management.Automation.ErrorRecord]) {
        $isBinding = $base.Exception -is [System.Management.Automation.ParameterBindingException]
        if ($isBinding) { $script:fatal = $base.Exception.Message }
        Write-PlxEvent 'error' (ConvertTo-PlxErrorData $base $isBinding)
    } elseif ($base -is [System.Management.Automation.WarningRecord]) {
        Write-PlxEvent 'warning' $base.Message
    } elseif ($base -is [System.Management.Automation.VerboseRecord]) {
        Write-PlxEvent 'verbose' $base.Message
    } elseif ($base -is [System.Management.Automation.DebugRecord]) {
        Write-PlxEvent 'debug' $base.Message
    } elseif ($base -is [System.Management.Automation.InformationRecord]) {
        $data = [ordered]@{ message = [string]$base.MessageData; tags = @($base.Tags); host = $false; fg = $null; bg = $null }
        if ($base.MessageData -is [System.Management.Automation.HostInformationMessage]) {
            $data.host = $true
            $data.message = $base.MessageData.Message
            if ($null -ne $base.MessageData.ForegroundColor) { $data.fg = [string]$base.MessageData.ForegroundColor }
            if ($null -ne $base.MessageData.BackgroundColor) { $data.bg = [string]$base.MessageData.BackgroundColor }
        }
        Write-PlxEvent 'info' $data
    } else {
        $typeName = $null
        if ($null -ne $item) { $typeName = @($item.PSObject.TypeNames)[0] }
        $display = $null
        $standard = $null
        if ($null -ne $item) { $standard = $item.PSObject.Members['PSStandardMembers'] }
        if ($standard -and $standard.Value.DefaultDisplayPropertySet) {
            $display = @($standard.Value.DefaultDisplayPropertySet.ReferencedPropertyNames)
        }
        $value = $null
        try { $value = ConvertTo-PlxValue $item } catch { $value = ($item | Out-String).Trim() }
        Write-PlxEvent 'output' $value @{ type = $typeName; display = $display }
    }
}

function Send-Progress($p) {
    Write-PlxEvent 'progress' ([ordered]@{
            id = $p.ActivityId; parentId = $p.ParentActivityId; activity = $p.Activity
            status = $p.StatusDescription; operation = $p.CurrentOperation
            percent = $p.PercentComplete; secondsRemaining = $p.SecondsRemaining
            completed = ($p.RecordType -eq [System.Management.Automation.ProgressRecordType]::Completed)
        })
}

function Receive-Streams {
    foreach ($item in $output.ReadAll()) { Send-Record $item }
    foreach ($item in $ps.Streams.Error.ReadAll()) { Send-Record $item }
    foreach ($p in $ps.Streams.Progress.ReadAll()) { Send-Progress $p }
}

$handle = $ps.BeginInvoke($inputData, $output)
while (-not $handle.IsCompleted) {
    Receive-Streams
    Start-Sleep -Milliseconds 25
}
try { $ps.EndInvoke($handle) } catch { $null = $_ }
Receive-Streams

$exitCode = 0
$exitValue = $ps.Runspace.SessionStateProxy.GetVariable('LASTEXITCODE')
if ($null -ne $exitValue) { $exitCode = [int]$exitValue }

$state = $ps.InvocationStateInfo
if ($state.State -eq [System.Management.Automation.PSInvocationState]::Failed) {
    $reason = $state.Reason
    $record = $null
    if ($reason -is [System.Management.Automation.IContainsErrorRecord]) { $record = $reason.ErrorRecord }
    if ($record) { Write-PlxEvent 'error' (ConvertTo-PlxErrorData $record $true) }
    else { Write-PlxEvent 'error' ([ordered]@{ message = $reason.Message; terminating = $true }) }
    $script:fatal = $reason.Message
}

$status = 'succeeded'
if ($script:fatal -or $exitCode -ne 0) { $status = 'failed' }
if ($exitCode -eq 0 -and $script:fatal) { $exitCode = 1 }
Write-PlxEvent 'exit' ([ordered]@{ status = $status; exitCode = $exitCode; error = $script:fatal })
$ps.Dispose()
exit $exitCode
