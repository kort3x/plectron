function Test-Port {
    <#
    .SYNOPSIS
    Check whether TCP ports are reachable.
    .DESCRIPTION
    Tries a TCP connection to every host/port combination and reports the
    result and latency. Works on every platform.
    .PARAMETER ComputerName
    Hosts to test.
    .PARAMETER Port
    Ports to test.
    .PARAMETER TimeoutMs
    How long to wait for each connection.
    .COMPONENT
    Network
    .EXAMPLE
    Test-Port -ComputerName example.com -Port 80,443
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]]$ComputerName,

        [int[]]$Port = @(80, 443),

        [ValidateRange(100, 30000)]
        [int]$TimeoutMs = 2000
    )
    $total = $ComputerName.Count * $Port.Count
    $n = 0
    foreach ($c in $ComputerName) {
        foreach ($p in $Port) {
            $n++
            Write-Progress -Activity 'Testing ports' -Status "$c`:$p" -PercentComplete ([int](100 * $n / $total))
            $client = New-Object System.Net.Sockets.TcpClient
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $open = $false
            $err = $null
            try {
                $task = $client.ConnectAsync($c, $p)
                $open = $task.Wait($TimeoutMs) -and $client.Connected
                if (-not $open) { $err = 'Timed out' }
            } catch {
                $err = $_.Exception.GetBaseException().Message
            } finally { $client.Dispose() }
            $sw.Stop()
            if (-not $open) { Write-Warning "$c`:$p is not reachable ($err)" }
            [pscustomobject]@{ Host = $c; Port = $p; Open = $open; LatencyMs = [int]$sw.ElapsedMilliseconds; Error = $err }
        }
    }
    Write-Progress -Activity 'Testing ports' -Completed
}
