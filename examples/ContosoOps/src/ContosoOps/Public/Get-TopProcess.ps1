function Get-TopProcess {
    <#
    .SYNOPSIS
    List the busiest processes on this machine.
    .DESCRIPTION
    Returns real Process objects. Open a row to see every property.
    .PARAMETER SortBy
    What to rank processes by.
    .PARAMETER Count
    Number of processes to return.
    .COMPONENT
    System
    #>
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param(
        [ValidateSet('CPU', 'WorkingSet', 'Handles', 'Id')]
        [string]$SortBy = 'WorkingSet',

        [ValidateRange(1, 100)]
        [int]$Count = 20,

        [string]$NameFilter
    )
    $procs = Get-Process
    if ($NameFilter) { $procs = $procs | Where-Object Name -like "*$NameFilter*" }
    $procs | Sort-Object $SortBy -Descending | Select-Object -First $Count
}
