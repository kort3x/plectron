# Child-side describer: imports one module (after the project's setup script)
# and reports its exported commands as tool schemas. Must stay 5.1-compatible.
param([Parameter(Mandatory)][string]$JobPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Private/Compat.ps1')
. (Join-Path $PSScriptRoot '../Private/Protocol.ps1')
. (Join-Path $PSScriptRoot '../Private/Discovery.ps1')
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$job = ConvertFrom-PlxJson (Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8)
Remove-Item -LiteralPath $JobPath -Force

try {
    if ($job.setup) { $null = . $job.setup }
    $module = Import-Module $job.module -PassThru -ErrorAction Stop | Select-Object -First 1
    $moduleId = ConvertTo-PlxSlug $module.Name
    $commands = Get-Command -Module $module.Name -CommandType Function, Filter, Cmdlet | Sort-Object Name
    $tools = @(foreach ($c in $commands) { ConvertTo-PlxCommandTool -Command $c -ModuleId $moduleId })
    Write-PlxEvent 'describe' @{ module = $module.Name; tools = $tools }
} catch {
    Write-PlxEvent 'describe' @{ error = $_.Exception.Message }
}
