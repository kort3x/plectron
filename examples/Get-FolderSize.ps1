<#
.SYNOPSIS
Find out which folders take up the most space.
.DESCRIPTION
Measures every sub-folder of a path and returns one object per folder,
sorted by size. Shows progress while it scans.
.PARAMETER Path
Folder to analyse.
.PARAMETER Top
How many folders to return.
.PARAMETER IncludeHidden
Also measure hidden folders.
.EXAMPLE
./Get-FolderSize.ps1 -Path ~/Downloads -Top 5
#>
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [ValidateRange(1, 500)]
    [int]$Top = 15,

    [switch]$IncludeHidden
)

$root = Resolve-Path -LiteralPath $Path -ErrorAction Stop
$dirs = @(Get-ChildItem -LiteralPath $root -Directory -Force:$IncludeHidden -ErrorAction SilentlyContinue)
Write-Verbose "Scanning $($dirs.Count) folders in $root" -Verbose
$i = 0
$results = foreach ($d in $dirs) {
    $i++
    Write-Progress -Activity "Measuring $root" -Status $d.Name -PercentComplete ([int](100 * $i / [math]::Max(1, $dirs.Count)))
    $files = Get-ChildItem -LiteralPath $d.FullName -File -Recurse -Force:$IncludeHidden -ErrorAction SilentlyContinue
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    [pscustomobject]@{
        Name     = $d.Name
        SizeMB   = [math]::Round($bytes / 1MB, 2)
        Files    = @($files).Count
        Modified = $d.LastWriteTime
        Path     = $d.FullName
    }
}
Write-Progress -Activity "Measuring $root" -Completed
$results | Sort-Object SizeMB -Descending | Select-Object -First $Top
Write-Host "Scanned $($dirs.Count) folders." -ForegroundColor Green
