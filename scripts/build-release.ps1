#!/usr/bin/env pwsh
# Builds Puny ReleaseSmall binaries for Windows, Linux, and macOS.
# Windows and Linux binaries are packed with UPX to stay under 1 MB.
# Run from the repository root.

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$upx = Get-Command upx -ErrorAction SilentlyContinue
if (-not $upx) {
    Write-Error "UPX is required but not found in PATH. Install it from https://upx.github.io/"
}

$targets = @(
    @{ Name = 'windows'; Triple = 'x86_64-windows-gnu'; Ext = '.exe' },
    @{ Name = 'linux'; Triple = 'x86_64-linux-gnu'; Ext = '' },
    @{ Name = 'macos'; Triple = 'x86_64-macos'; Ext = '' }
)

$releaseDir = 'zig-out/release'
if (Test-Path $releaseDir) {
    Remove-Item -Recurse -Force $releaseDir
}
New-Item -ItemType Directory -Path $releaseDir | Out-Null

function Format-Size([long]$Bytes) {
    '{0,10} bytes = {1,8:F2} KB = {2,8:F2} MB' -f $Bytes, ($Bytes / 1KB), ($Bytes / 1MB)
}

Write-Host 'Building Puny release binaries...' -ForegroundColor Cyan

foreach ($t in $targets) {
    $outDir = "zig-out/bin-$($t.Triple)"
    if (Test-Path $outDir) {
        Remove-Item -Recurse -Force $outDir
    }

    $buildArgs = @('build', '-Doptimize=ReleaseSmall', "-Dtarget=$($t.Triple)", '--prefix', $outDir)
    $buildOutput = & zig @buildArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host $buildOutput -ForegroundColor Red
        Write-Error "Build failed for $($t.Triple)"
    }

    $src = Get-ChildItem -Path "$outDir/bin" -File | Select-Object -First 1
    if (-not $src) {
        Write-Error "No binary found for $($t.Triple)"
    }

    $unpackedSize = $src.Length
    $destName = "puny-$($t.Name)$($t.Ext)"
    $dest = Join-Path $releaseDir $destName

    if ($t.Name -in @('windows', 'linux')) {
        & upx --best "$($src.FullName)" -o $dest 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "UPX failed for $($t.Triple)"
        }
    } else {
        Copy-Item $src.FullName $dest
    }

    $packedSize = (Get-Item $dest).Length
    $ratio = 100 * $packedSize / $unpackedSize
    $ratioText = '{0,5:F1}%' -f $ratio
    Write-Host "$($t.name.PadRight(7)) unpacked: $(Format-Size -Bytes $unpackedSize)  packed: $(Format-Size -Bytes $packedSize)  ratio: $ratioText"
}

Write-Host "Release binaries written to $releaseDir" -ForegroundColor Green
