@{
    RootModule           = 'Plectron.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6d0b3c8e-4f0e-4b8a-9a52-2f7f5d1c9e41'
    Author               = 'Manuel Berfelde'
    Description          = 'A pretty HTML front end for PowerShell scripts: auto-generated forms, live output, rich object views and run history.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    NestedModules        = @('Private/Plectron.Core.psm1')
    FunctionsToExport    = @('Start-Plectron', 'Stop-Plectron', 'Get-Plectron')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{ PSData = @{ Tags = @('UI', 'Web', 'GUI', 'Tools', 'PSEdition_Desktop', 'PSEdition_Core', 'Windows', 'Linux', 'MacOS') } }
}
