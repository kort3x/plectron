# Child-side host. Runs one tool script inside a nested PowerShell instance and
# reports every stream as protocol events on stdout. Must stay 5.1-compatible.
param([Parameter(Mandatory)][string]$JobPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Private/Compat.ps1')
. (Join-Path $PSScriptRoot '../Private/Protocol.ps1')
. (Join-Path $PSScriptRoot '../Private/Streams.ps1')
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
$result = Invoke-PlxStreamed -PowerShell $ps

$exitCode = 0
$exitValue = $ps.Runspace.SessionStateProxy.GetVariable('LASTEXITCODE')
if ($null -ne $exitValue) { $exitCode = [int]$exitValue }

$status = $result.status
if ($exitCode -ne 0) { $status = 'failed' }
if ($exitCode -eq 0 -and $status -eq 'failed') { $exitCode = 1 }
Write-PlxEvent 'exit' ([ordered]@{ status = $status; exitCode = $exitCode; error = $result.error })
$ps.Dispose()
exit $exitCode
