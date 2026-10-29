<#
.SYNOPSIS
Find and end processes on this machine.
#>
New-PlxPage -Title 'Task manager' -Description 'The table holds real Process objects; the buttons act on the ones you select.' {
    New-PlxRow {
        New-PlxTextBox -Name Filter -Label 'Name contains' -Placeholder 'e.g. code' -Refresh Processes
        New-PlxDropdown -Name SortBy -Label 'Sort by' -Options 'WorkingSet', 'CPU', 'Id', 'Name' -Default 'WorkingSet' -Refresh Processes
    }
    New-PlxTable -Name Processes -Title 'Processes' -Key Id -Property Name, Id, CPU, WorkingSet -AutoRefresh 10 -ScriptBlock {
        Get-Process | Where-Object Name -like "*$Filter*" | Sort-Object $SortBy -Descending:($SortBy -ne 'Name') | Select-Object -First 200
    }
    New-PlxRow {
        New-PlxButton 'Details' -Output Details -ScriptBlock {
            if (-not $Processes) { Show-PlxMessage 'Select one or more processes first.' -Level Warning; return }
            $Processes | Select-Object Name, Id, StartTime, Path, @{ n = 'Memory (MB)'; e = { [math]::Round($_.WorkingSet64 / 1MB, 1) } }
        }
        New-PlxButton 'End task' -Variant Danger -Confirm 'End the selected processes?' -Refresh Processes -ScriptBlock {
            if (-not $Processes) { Show-PlxMessage 'Select one or more processes first.' -Level Warning; return }
            $Processes | Stop-Process -ErrorAction Continue
            Show-PlxMessage "Ended $(@($Processes).Count) process(es)." -Level Success
        }
    }
    New-PlxOutput -Name Details -Title 'Details'
}
