@{
    Title    = 'Fixture Ops'
    Accent   = '#ff0066'
    Logo     = './logo.svg'
    Modules  = @('../module/FixtureTools/FixtureTools.psd1')
    Scripts  = @('../tools')
    Exclude  = @('Invoke-Fail', 'Broken')
    Setup    = './setup.ps1'
    Commands = @{
        'Invoke-Echo' = @{ Title = 'Echo!'; Category = 'Fun'; Parameters = @{ Text = @{ Widget = 'textarea' } } }
        'Get-Widget'  = @{ Category = 'Overridden' }
    }
}
