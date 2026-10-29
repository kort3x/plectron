<#
.SYNOPSIS
Fixture page.
.DESCRIPTION
Used by the page tests.
#>
$script:items = @(1..3 | ForEach-Object { [pscustomobject]@{ Name = "item$_"; Size = $_ * 10 } })
$script:counter = 0

New-PlxPage -Title 'Fixture page' {
    New-PlxRow {
        New-PlxTextBox -Name Filter -Refresh Items
        New-PlxDropdown -Name Pick -Options 'a', 'b' -Default 'b'
        New-PlxNumber -Name Limit -Default 5
        New-PlxCheckbox -Name Loud
    }
    New-PlxTable -Name Items -Property Name, Size -ScriptBlock {
        Write-Warning 'loading items'
        $script:items | Where-Object Name -like "*$Filter*"
    }
    New-PlxChart -Name Sizes -X Name -Y Size -ScriptBlock { $script:items }
    New-PlxDropdown -Name Kinds -ScriptBlock { 'x', 'y' }
    New-PlxButton 'Inspect' -Name Inspect -Output Log -ScriptBlock {
        "same:$([object]::ReferenceEquals(@($Items)[0], $script:items[1]))"
        "count:$(@($Items).Count) selected:$(@($Selected).Count)"
        "pick:$Pick limit:$Limit loud:$Loud filter:[$Filter]"
    }
    New-PlxButton 'Count' -Name Count -ScriptBlock { $script:counter++; "counter:$script:counter" }
    New-PlxButton 'Remove' -Name Remove -Variant Danger -Refresh Items -ScriptBlock {
        $script:items = @($script:items | Where-Object { @($Items) -notcontains $_ })
        Show-PlxMessage 'Removed' -Level Success
    }
    New-PlxButton 'Slow' -Name Slow -ScriptBlock { Write-Progress -Activity 'Waiting' -PercentComplete 10; Start-Sleep -Seconds 30 }
    New-PlxButton 'Fail' -Name Fail -ScriptBlock { throw 'action failed' }
    New-PlxOutput -Name Log
    New-PlxText 'Some **text**' -Markdown
}
