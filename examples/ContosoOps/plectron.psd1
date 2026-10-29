# Plectron project file. Everything here is optional: categories already come
# from each function's .COMPONENT help keyword and hidden helpers from .ROLE.
@{
    Title    = 'Contoso Ops'
    Logo     = './assets/logo.svg'
    Accent   = '#0a7cff'
    Modules  = @('./src/ContosoOps/ContosoOps.psd1')
    Scripts  = @('./scripts')
    Pages    = @('./pages')
    Setup    = './dev/Initialize.ps1'
    Commands = @{
        'Get-FolderSize'   = @{ Title = 'Folder sizes'; Icon = 'disk'; Parameters = @{ Path = @{ Placeholder = '~/Downloads' } } }
        'Get-TopProcess'   = @{ Title = 'Top processes'; Icon = 'chart'; Parameters = @{ NameFilter = @{ Label = 'Name contains' } } }
        'Test-Port'        = @{ Title = 'Port check'; Icon = 'network' }
        'Invoke-Deployment' = @{ Title = 'Deploy (demo)'; Icon = 'package' }
        'New-Greeting'     = @{ Title = 'Greeting playground'; Icon = 'star'; Parameters = @{ Note = @{ Widget = 'textarea' } } }
        'Get-EnvironmentInfo' = @{ Title = 'Environment'; Icon = 'gear' }
    }
}
