$script:PlxServers = New-Object System.Collections.Generic.List[object]
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Export-ModuleMember -Function 'Start-Plectron', 'Show-Plectron', 'Stop-Plectron', 'Get-Plectron', 'New-PlxPage', 'New-PlxRow', 'New-PlxColumn', 'New-PlxCard', 'New-PlxTabs', 'New-PlxTab', 'New-PlxTable', 'New-PlxChart', 'New-PlxTextBox', 'New-PlxDropdown', 'New-PlxCheckbox', 'New-PlxNumber', 'New-PlxButton', 'New-PlxText', 'New-PlxOutput', 'Show-PlxMessage', 'Show-PlxPage'
