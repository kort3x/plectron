function Get-Widget {
    <#
    .SYNOPSIS
    Lists widgets.
    .DESCRIPTION
    Fixture with parameter sets.
    .PARAMETER Name
    Widget name.
    .COMPONENT
    Inventory
    .EXAMPLE
    Get-Widget -Name a
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [string]$Name,

        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [int]$Id,

        [ValidateSet('Small', 'Large')]
        [string]$Size = 'Small'
    )
    [pscustomobject]@{ Name = $Name; Id = $Id; Size = $Size; Set = $PSCmdlet.ParameterSetName }
}

function Invoke-Echo {
    <#
    .SYNOPSIS
    Echoes text.
    #>
    param([string]$Text = 'echo', [securestring]$Secret)
    $Text
    "setup:$env:PLX_FIXTURE_SETUP"
    "cwd:$((Get-Location).Path)"
    if ($Secret) { 'secret:' + [System.Net.NetworkCredential]::new('', $Secret).Password }
}

function Get-Inline([string]$Name = 'inline') { $Name }

function Invoke-Fail {
    param([int]$Code = 3)
    Write-Error 'failing'
    exit $Code
}

function Remove-Internal {
    <#
    .SYNOPSIS
    Internal helper.
    .ROLE
    Hidden
    #>
    param()
    'internal'
}

function Get-Private { 'not exported' }
