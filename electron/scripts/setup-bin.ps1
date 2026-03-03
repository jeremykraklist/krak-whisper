# setup-bin.ps1 — Copy whisper.cpp binaries to electron/bin/
# Run this from the electron/ directory on the Windows PC

$ErrorActionPreference = "Stop"

$whisperBuildDir = "C:\Users\jerem\Projects\whisper.cpp\build\bin\Release"
$whisperBuildDirAlt = "C:\Users\jerem\Projects\whisper.cpp\build\bin"
$binDir = Join-Path $PSScriptRoot "..\bin"

# Create bin directory if it doesn't exist
if (-not (Test-Path $binDir)) {
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
}

# Determine the source directory
$sourceDir = if (Test-Path $whisperBuildDir) { $whisperBuildDir } else { $whisperBuildDirAlt }

Write-Host "Copying whisper.cpp binaries from: $sourceDir" -ForegroundColor Cyan

$files = @(
    "whisper-cli.exe",
    "whisper.dll",
    "ggml-cpu.dll",
    "ggml.dll",
    "ggml-base.dll"
)

$copied = 0
foreach ($file in $files) {
    $srcPath = Join-Path $sourceDir $file
    if (Test-Path $srcPath) {
        Copy-Item $srcPath -Destination $binDir -Force
        Write-Host "  ✓ Copied $file" -ForegroundColor Green
        $copied++
    } else {
        Write-Host "  ⚠ Not found: $file (may not be needed)" -ForegroundColor Yellow
    }
}

# Also copy any other .dll files from the build dir that might be needed
Get-ChildItem -Path $sourceDir -Filter "*.dll" | ForEach-Object {
    if ($files -notcontains $_.Name) {
        Copy-Item $_.FullName -Destination $binDir -Force
        Write-Host "  ✓ Copied $($_.Name) (extra DLL)" -ForegroundColor Green
        $copied++
    }
}

Write-Host "`n$copied files copied to bin/" -ForegroundColor Cyan

# Verify whisper-cli.exe exists
$cliPath = Join-Path $binDir "whisper-cli.exe"
if (Test-Path $cliPath) {
    Write-Host "✅ whisper-cli.exe ready!" -ForegroundColor Green
} else {
    Write-Host "❌ whisper-cli.exe NOT found! Build whisper.cpp first." -ForegroundColor Red
    exit 1
}
