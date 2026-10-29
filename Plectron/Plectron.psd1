@{
    RootModule           = 'Plectron.psm1'
    ModuleVersion        = '0.3.0'
    GUID                 = '6d0b3c8e-4f0e-4b8a-9a52-2f7f5d1c9e41'
    Author               = 'Manuel Berfelde'
    Copyright            = '(c) 2026 Manuel Berfelde. MIT License.'
    Description          = 'An HTML frontend for PowerShell modules and scripts: auto-generated forms, live output, object views and run history.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    NestedModules        = @('Private/Plectron.Core.psm1')
    FunctionsToExport    = @(
        'Start-Plectron', 'Show-Plectron', 'Stop-Plectron', 'Get-Plectron',
        'New-PlxPage', 'New-PlxRow', 'New-PlxColumn', 'New-PlxCard',
        'New-PlxTabs', 'New-PlxTab', 'New-PlxTable', 'New-PlxChart',
        'New-PlxTextBox', 'New-PlxDropdown', 'New-PlxCheckbox', 'New-PlxNumber',
        'New-PlxButton', 'New-PlxText', 'New-PlxOutput', 'Show-PlxMessage',
        'Show-PlxPage'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('UI', 'Web', 'GUI', 'HTML', 'Forms', 'Tools', 'Show-Command', 'PSEdition_Desktop', 'PSEdition_Core', 'Windows', 'Linux', 'MacOS')
            LicenseUri   = 'https://github.com/kort3x/plectron/blob/master/LICENSE'
            ProjectUri   = 'https://github.com/kort3x/plectron'
            ReleaseNotes = 'Custom pages: a New-Plx* layout DSL with tables, charts, inputs and buttons backed by a persistent page process.'
        }
    }
}
