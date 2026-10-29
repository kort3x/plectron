function Invoke-Deployment {
    <#
    .SYNOPSIS
    Simulated deployment with nested progress, warnings and errors.
    .DESCRIPTION
    Nothing is actually deployed. This demo shows parameter sets, nested
    progress bars, every output stream, and how a terminating error becomes
    a failed run.
    .PARAMETER Environment
    Named environment to deploy to.
    .PARAMETER Url
    Custom target URL (the 'Custom' parameter set).
    .PARAMETER Services
    Services to roll out.
    .PARAMETER FailAt
    Make the deployment fail at this service.
    .COMPONENT
    Release
    #>
    [CmdletBinding(DefaultParameterSetName = 'Named')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Named')]
        [ValidateSet('Development', 'Staging', 'Production')]
        [string]$Environment,

        [Parameter(Mandatory, ParameterSetName = 'Custom')]
        [ValidatePattern('^https?://')]
        [string]$Url,

        [ValidateSet('api', 'web', 'worker', 'scheduler')]
        [string[]]$Services = @('api', 'web', 'worker'),

        [string]$FailAt,

        [switch]$DryRun
    )
    $target = $Environment
    if ($PSCmdlet.ParameterSetName -eq 'Custom') { $target = $Url }
    Write-Host "Deploying to $target" -ForegroundColor Cyan
    if ($DryRun) { Write-Warning 'Dry run: nothing will change.' }
    if ($Environment -eq 'Production') { Write-Warning 'You are deploying to PRODUCTION.' }

    $steps = 'Build', 'Upload', 'Migrate', 'Health check'
    $s = 0
    foreach ($svc in $Services) {
        $s++
        Write-Progress -Id 1 -Activity 'Deploying services' -Status $svc -PercentComplete ([int](100 * ($s - 1) / $Services.Count))
        $t = 0
        foreach ($step in $steps) {
            $t++
            Write-Progress -Id 2 -ParentId 1 -Activity $svc -Status $step -PercentComplete ([int](100 * $t / $steps.Count))
            Write-Verbose "[$svc] $step" -Verbose
            Start-Sleep -Milliseconds (Get-Random -Minimum 150 -Maximum 450)
        }
        Write-Progress -Id 2 -Activity $svc -Completed
        # Functions throw instead of calling exit, which would close the caller's shell.
        if ($svc -eq $FailAt) { throw "Health check failed for $svc" }
        [pscustomobject]@{ Service = $svc; Target = $target; Version = '1.4.{0}' -f (Get-Random -Maximum 99); Status = 'Deployed'; DryRun = [bool]$DryRun }
    }
    Write-Progress -Id 1 -Activity 'Deploying services' -Completed
    Write-Host 'All services deployed.' -ForegroundColor Green
}
