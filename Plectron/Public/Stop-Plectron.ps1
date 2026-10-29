function Stop-Plectron {
    <#
    .SYNOPSIS
    Stop a running Plectron server (all of them when -Server is omitted).
    Running tools are cancelled.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$Server)
    process {
        $targets = @($Server)
        if (-not $Server) { $targets = @($script:PlxServers) }
        foreach ($s in $targets) {
            Stop-PlxServer -State $s.State -Server $s.Handles
            $null = $script:PlxServers.Remove($s)
        }
    }
}

function Get-Plectron {
    <#
    .SYNOPSIS
    List the Plectron servers running in this session.
    #>
    [CmdletBinding()]
    param()
    $script:PlxServers.ToArray()
}
