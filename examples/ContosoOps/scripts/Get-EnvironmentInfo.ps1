<#
.SYNOPSIS
Shows which PowerShell runs the tools and what the setup script prepared.
.DESCRIPTION
A loose script next to the module: projects can mix scripts and module commands.
.COMPONENT
Diagnostics
#>
param()
[pscustomobject]@{
    Edition     = $PSVersionTable.PSEdition
    Version     = "$($PSVersionTable.PSVersion)"
    OS          = [Environment]::OSVersion.VersionString
    Environment = $env:CONTOSO_ENVIRONMENT
    Location    = (Get-Location).Path
}
