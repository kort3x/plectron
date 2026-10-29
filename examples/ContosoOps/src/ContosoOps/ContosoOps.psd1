@{
    RootModule        = 'ContosoOps.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '3c1f0d64-2f35-4a63-a8a2-6c2c1f5a9e77'
    Author            = 'Contoso'
    Description       = 'Example operations module that ships a Plectron web UI.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-FolderSize', 'Get-TopProcess', 'Test-Port', 'Invoke-Deployment', 'New-Greeting', 'Start-ContosoUI')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
