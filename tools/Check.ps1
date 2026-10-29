# Static checks: parse every script and verify syntax compatibility with
# Windows PowerShell 5.1 (the oldest supported engine).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$files = Get-ChildItem -Path (Join-Path $root 'Plectron'), (Join-Path $root 'examples') -Include '*.ps1', '*.psm1', '*.psd1' -Recurse
$failed = $false
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) { $failed = $true; Write-Host "$($f.FullName):$($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red }
}
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $settings = @{
        IncludeRules = @('PSUseCompatibleSyntax')
        Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.0') } }
    }
    $issues = $files | Where-Object Extension -ne '.psd1' | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings $settings }
    foreach ($i in $issues) { $failed = $true; Write-Host "$($i.ScriptPath):$($i.Line): $($i.Message)" -ForegroundColor Red }
} else {
    Write-Warning 'PSScriptAnalyzer not installed; skipping 5.1 compatibility check.'
}
if ($failed) { exit 1 }
Write-Host "OK: $($files.Count) files" -ForegroundColor Green
