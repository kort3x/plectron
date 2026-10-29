function Start-ContosoUI {
    <#
    .SYNOPSIS
    Opens the Contoso Ops web UI.
    .DESCRIPTION
    Uses an installed Plectron module when there is one, otherwise the copy
    in this repository. Pass -NoBrowser or -PassThru through to Start-Plectron.
    .ROLE
    Hidden
    #>
    [CmdletBinding()]
    param([switch]$NoBrowser, [switch]$PassThru)
    if (-not (Get-Command Start-Plectron -ErrorAction SilentlyContinue)) {
        if (Get-Module -ListAvailable Plectron) { Import-Module Plectron -ErrorAction Stop }
        else { Import-Module (Join-Path $PSScriptRoot '../../../../../Plectron/Plectron.psd1') -ErrorAction Stop }
    }
    Start-Plectron -Config (Join-Path $PSScriptRoot '../../../plectron.psd1') @PSBoundParameters
}
