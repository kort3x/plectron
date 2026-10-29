function New-Greeting {
    <#
    .SYNOPSIS
    Shows every kind of form field Plectron can generate.
    .DESCRIPTION
    A playground: each parameter uses a different type or validation
    attribute. The function just echoes what it received.
    .PARAMETER Name
    Who to greet.
    .PARAMETER Mood
    Picked from a ValidateSet.
    .PARAMETER Times
    A ValidateRange'd integer.
    .PARAMETER Shout
    A switch.
    .PARAMETER Languages
    A ValidateSet on an array becomes multi-select pills.
    .PARAMETER Tags
    Free-form string array.
    .PARAMETER When
    A DateTime.
    .PARAMETER Day
    An enum.
    .PARAMETER ApiKey
    A SecureString, never stored in history.
    .PARAMETER Login
    A PSCredential.
    .PARAMETER ZipCode
    Validated by ValidatePattern.
    .PARAMETER Note
    Shown as a textarea thanks to plectron.psd1.
    .COMPONENT
    Demos
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [ValidateSet('Happy', 'Calm', 'Excited')]
        [string]$Mood = 'Happy',

        [ValidateRange(1, 5)]
        [int]$Times = 1,

        [switch]$Shout,

        [ValidateSet('English', 'German', 'Spanish', 'Japanese')]
        [string[]]$Languages = @('English'),

        [string[]]$Tags,

        [datetime]$When,

        [System.DayOfWeek]$Day,

        [securestring]$ApiKey,

        [pscredential]$Login,

        [ValidatePattern('^\d{5}$')]
        [string]$ZipCode,

        [string]$Note
    )
    $words = @{ English = 'Hello'; German = 'Hallo'; Spanish = 'Hola'; Japanese = 'Konnichiwa' }
    $colors = @{ Happy = 'Yellow'; Calm = 'Cyan'; Excited = 'Magenta' }
    foreach ($i in 1..$Times) {
        foreach ($l in $Languages) {
            $text = "$($words[$l]), $Name!"
            if ($Shout) { $text = $text.ToUpper() }
            Write-Host $text -ForegroundColor $colors[$Mood]
        }
    }
    if ($ApiKey) { Write-Information "Received an API key of length $($ApiKey.Length)." -InformationAction Continue }
    if ($Login) { Write-Information "Logged in as $($Login.UserName)." -InformationAction Continue }
    [pscustomobject]@{
        Name = $Name; Mood = $Mood; Times = $Times; Shout = [bool]$Shout
        Languages = $Languages; Tags = $Tags; When = $When; Day = $Day; ZipCode = $ZipCode; Note = $Note
        Engine = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
    }
}
