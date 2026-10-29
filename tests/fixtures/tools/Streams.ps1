[CmdletBinding()]
param(
    [int]$ExitCode = 0,
    [switch]$Throw,
    [string]$Text = 'plain',
    [securestring]$Secret,
    [pscredential]$Cred,
    [switch]$Slow
)
Write-Output $Text
[pscustomobject]@{ Name = 'alpha'; Size = 1; When = [datetime]'2024-01-02T03:04:05Z'; Nested = @{ Inner = 'x' } }
Write-Warning 'careful'
Write-Verbose 'verbose msg' -Verbose
Write-Error 'non-terminating'
Write-Information 'info msg'
Write-Host 'host msg' -ForegroundColor Green
Write-Progress -Activity 'Working' -Status 'Half' -PercentComplete 50 -Id 1
Write-Progress -Activity 'Working' -Completed -Id 1
if ($Secret) { 'secret:' + [System.Net.NetworkCredential]::new('', $Secret).Password }
if ($Cred) { 'cred:' + $Cred.UserName + ':' + $Cred.GetNetworkCredential().Password }
if ($Slow) { Start-Sleep -Seconds 30 }
if ($Throw) { throw 'boom' }
exit $ExitCode
