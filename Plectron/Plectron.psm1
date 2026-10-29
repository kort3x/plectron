$script:PlxServers = New-Object System.Collections.Generic.List[object]
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Export-ModuleMember -Function 'Start-Plectron', 'Show-Plectron', 'Stop-Plectron', 'Get-Plectron'
