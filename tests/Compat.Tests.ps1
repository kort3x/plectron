BeforeAll {
    Import-Module "$PSScriptRoot/../Plectron/Private/Plectron.Core.psm1" -Force
}

Describe 'ConvertFrom-PlxJson' {
    It 'returns nested hashtables and arrays' {
        $r = ConvertFrom-PlxJson '{"a":1,"b":{"c":"x"},"d":[1,{"e":true}],"n":null}'
        $r | Should -BeOfType [hashtable]
        $r.a | Should -Be 1
        $r.b | Should -BeOfType [hashtable]
        $r.b.c | Should -Be 'x'
        $r.d.Count | Should -Be 2
        $r.d[1].e | Should -BeTrue
        $r.ContainsKey('n') | Should -BeTrue
        $r.n | Should -BeNullOrEmpty
    }
    It 'keeps single-element arrays as arrays' {
        $r = ConvertFrom-PlxJson '{"d":["only"]}'
        , $r.d | Should -BeOfType [object[]]
    }
}

Describe 'ConvertTo-PlxJson' {
    It 'emits compact json and keeps single-element arrays' {
        ConvertTo-PlxJson @{ a = @(1) } | Should -Be '{"a":[1]}'
    }
    It 'serialises an empty array' {
        ConvertTo-PlxJson @() | Should -Be '[]'
    }
}

Describe 'ConvertTo-PlxValue' {
    It 'passes primitives through' {
        ConvertTo-PlxValue 5 | Should -Be 5
        ConvertTo-PlxValue 'x' | Should -Be 'x'
        ConvertTo-PlxValue $true | Should -BeTrue
    }
    It 'formats dates as ISO 8601' {
        ConvertTo-PlxValue ([datetime]::new(2024, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)) | Should -Be '2024-01-02T03:04:05.0000000Z'
    }
    It 'turns enums into strings' {
        ConvertTo-PlxValue ([System.DayOfWeek]::Monday) | Should -Be 'Monday'
    }
    It 'flattens objects to property bags' {
        $v = ConvertTo-PlxValue ([pscustomobject]@{ A = 1; B = [pscustomobject]@{ C = 'd' } })
        $v.A | Should -Be 1
        $v.B.C | Should -Be 'd'
    }
    It 'stops recursing at the depth limit with ToString' {
        $v = ConvertTo-PlxValue ([pscustomobject]@{ A = [pscustomobject]@{ B = 'x' } }) -Depth 1
        $v.A | Should -BeOfType [string]
    }
    It 'converts lists and dictionaries' {
        $v = ConvertTo-PlxValue @{ k = @(1, 2) }
        $v.k.Count | Should -Be 2
    }
}
