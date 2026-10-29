<#
.SYNOPSIS
A demo dashboard with charts, filters and a long-running action.
.DESCRIPTION
The servers are made up and live in this page's own process, so restarting
them changes the page's state, not your machine.
#>
$script:regions = 'eu-west', 'us-east', 'ap-south'
$script:servers = @(foreach ($i in 1..12) {
        [pscustomobject]@{
            Name   = 'web-{0:00}' -f $i
            Region = $script:regions[$i % 3]
            Cpu    = Get-Random -Minimum 5 -Maximum 95
            Memory = Get-Random -Minimum 20 -Maximum 90
            Status = 'Running'
            Uptime = Get-Random -Minimum 1 -Maximum 400
        }
    })

New-PlxPage -Title 'Fleet dashboard' -Description 'Made-up servers, so feel free to restart them.' {
    New-PlxRow {
        New-PlxDropdown -Name Region -Label 'Region' -Options (@('All') + $script:regions) -Default 'All' -Refresh Servers, Load
        New-PlxNumber -Name MinCpu -Label 'Minimum CPU %' -Default 0 -Min 0 -Max 100 -Refresh Servers, Load
    }
    New-PlxRow {
        New-PlxColumn -Width 2 {
            New-PlxChart -Name Load -Title 'CPU and memory by server (%)' -Type Bar -X Name -Y Cpu, Memory -ScriptBlock {
                $script:servers | Where-Object { ($Region -eq 'All' -or $_.Region -eq $Region) -and $_.Cpu -ge $MinCpu }
            }
        }
        New-PlxColumn {
            New-PlxCard -Title 'About' {
                New-PlxText -Markdown @'
Select servers in the table, then **Restart**. The action runs in this page's
own PowerShell process and streams its progress into the output panel.

- Filters re-run the table and chart `-ScriptBlock`s
- `$Servers` holds the *selected* objects
'@
            }
        }
    }
    New-PlxTabs {
        New-PlxTab 'Servers' {
            New-PlxTable -Name Servers -Title 'Servers' -Key Name -ScriptBlock {
                $script:servers | Where-Object { ($Region -eq 'All' -or $_.Region -eq $Region) -and $_.Cpu -ge $MinCpu }
            }
            New-PlxRow {
                New-PlxButton 'Restart' -Variant Primary -Output Log -Confirm 'Restart the selected servers?' -Refresh Servers, Load -ScriptBlock {
                    if (-not $Servers) { Show-PlxMessage 'Select servers to restart.' -Level Warning; return }
                    $n = 0
                    foreach ($s in $Servers) {
                        $n++
                        Write-Progress -Activity 'Restarting' -Status $s.Name -PercentComplete (100 * $n / @($Servers).Count)
                        Write-Host "Restarting $($s.Name)…" -ForegroundColor Cyan
                        Start-Sleep -Milliseconds 600
                        $s.Cpu = Get-Random -Minimum 2 -Maximum 15
                        $s.Uptime = 0
                    }
                    Write-Progress -Activity 'Restarting' -Completed
                    Show-PlxMessage "Restarted $n server(s)." -Level Success
                }
                New-PlxButton 'Mark for maintenance' -Output Log -Refresh Servers -ScriptBlock {
                    foreach ($s in $Servers) { $s.Status = 'Maintenance'; "$($s.Name) is now in maintenance." }
                }
            }
        }
        New-PlxTab 'Uptime' {
            New-PlxChart -Name Uptime -Title 'Uptime (days)' -Type Line -X Name -Y Uptime -ScriptBlock { $script:servers }
        }
    }
    New-PlxOutput -Name Log -Title 'Activity'
}
