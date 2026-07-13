#!/usr/bin/env pwsh
# Measures Puny ReleaseSmall binary sizes for common targets.
# Run from the repository root.

param(
    [string[]]$Targets = @('native', 'x86_64-linux-gnu', 'x86_64-windows-gnu', 'x86_64-macos', 'aarch64-macos')
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

function Format-Size([long]$Bytes) {
    '{0,10} bytes = {1,8:F2} KB = {2,8:F2} MB' -f $Bytes, ($Bytes / 1KB), ($Bytes / 1MB)
}

Write-Host 'Puny ReleaseSmall binary sizes'
Write-Host '================================'

foreach ($target in $Targets) {
    $outDir = "zig-out\bin-$target"
    if (Test-Path $outDir) {
        Remove-Item -Recurse -Force $outDir
    }

    $buildArgs = @('build', '-Doptimize=ReleaseSmall', "--prefix", $outDir)
    if ($target -ne 'native') {
        $buildArgs += "-Dtarget=$target"
    }

    & zig $buildArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "$target : build failed" -ForegroundColor Red
        continue
    }

    $exe = Get-ChildItem -Path "$outDir\bin" -File | Select-Object -First 1
    if (-not $exe) {
        Write-Host "$target : no output binary found" -ForegroundColor Yellow
        continue
    }

    $size = $exe.Length
    $statusColor = if ($size -lt 1MB) { 'Green' } else { 'Yellow' }
    Write-Host ($target.PadRight(20) + ' ' + (Format-Size -Bytes $size)) -ForegroundColor $statusColor
}
