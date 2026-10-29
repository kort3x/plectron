@{
    Title       = 'Pretty Sidecar'
    Category    = 'Demo'
    Icon        = 'star'
    Description = 'Overridden description.'
    Output      = 'text'
    Parameters  = @{
        Body  = @{ Label = 'Message body'; Widget = 'textarea'; Order = 2; Placeholder = 'Type here' }
        Title = @{ Order = 1 }
    }
}
