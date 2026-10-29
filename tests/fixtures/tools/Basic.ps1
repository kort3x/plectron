<#
.SYNOPSIS
Basic fixture tool.
.DESCRIPTION
Exercises every widget mapping.
.PARAMETER Name
Who to greet.
.EXAMPLE
./Basic.ps1 -Name World
#>
param(
    [Parameter(Mandatory, HelpMessage = 'Name to use')]
    [string]$Name,

    [ValidateSet('Low', 'High')]
    [string]$Level = 'Low',

    [ValidateRange(1, 10)]
    [int]$Count = 3,

    [switch]$Force,

    [string[]]$Tags = @('one', 'two'),

    [ValidateSet('a', 'b', 'c')]
    [string[]]$Letters,

    [datetime]$When,

    [securestring]$Secret,

    [pscredential]$Cred,

    [ValidatePattern('^\d+$')]
    [string]$Code,

    [bool]$Enabled = $true,

    [System.DayOfWeek]$Day,

    [double]$Ratio = 0.5,

    $Untyped,

    [string]$Computed = (Get-Date).ToString()
)
"Hello $Name"
