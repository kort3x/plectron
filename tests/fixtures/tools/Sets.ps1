[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [string]$Name,

    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [int]$Id,

    [string]$Common
)
$PSCmdlet.ParameterSetName
