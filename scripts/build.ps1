#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location (Join-Path $scriptDir "..")

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,
        [string[]] $ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE."
    }
}

Write-Host "=== 1. Build Python binary ===" -ForegroundColor Cyan

if (-not (Test-Path ".venv\Scripts\python.exe")) {
    Write-Host "  -> .venv not found. Creating it now." -ForegroundColor Yellow
    if (Get-Command py -ErrorAction SilentlyContinue) {
        & py -3 -m venv .venv
    } elseif (Get-Command python -ErrorAction SilentlyContinue) {
        & python -m venv .venv
    } else {
        throw "Python 3 was not found. Install Python and add it to PATH, then run this script again."
    }
}

Invoke-Checked ".venv\Scripts\python.exe" @("-m", "pip", "install", "-q", "-r", "python\requirements.txt")

$projectRoot = (Get-Location).Path
$pyinstallerWorkDir = Join-Path $projectRoot "build\pyinstaller_windows"

if (Test-Path "python\ppt_tool.exe") { Remove-Item -Force "python\ppt_tool.exe" }
if (Test-Path $pyinstallerWorkDir) { Remove-Item -Recurse -Force $pyinstallerWorkDir }
New-Item -ItemType Directory -Force -Path $pyinstallerWorkDir | Out-Null

Invoke-Checked ".venv\Scripts\python.exe" @(
    "-m",
    "PyInstaller",
    "--noconfirm",
    "--clean",
    "--onefile",
    "python\ppt_tool.py",
    "--distpath",
    "python",
    "--workpath",
    $pyinstallerWorkDir,
    "--specpath",
    $pyinstallerWorkDir,
    "--name",
    "ppt_tool",
    "--add-data=$projectRoot\assets\fonts\Pretendard-Bold.ttf;fonts",
    "--add-data=$projectRoot\assets\fonts\Pretendard-Regular.ttf;fonts"
)

if (-not (Test-Path "python\ppt_tool.exe")) {
    throw "PyInstaller completed but python\ppt_tool.exe was not created."
}
Write-Host "  -> Created python\ppt_tool.exe" -ForegroundColor Green

Write-Host ""
Write-Host "=== 2. Build Flutter Windows release ===" -ForegroundColor Cyan
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "Flutter was not found. Add the Flutter SDK bin folder to PATH, then run this script again."
}
Invoke-Checked "flutter" @("build", "windows", "--release")
Write-Host "  -> Created build\windows\x64\runner\Release" -ForegroundColor Green

Write-Host ""
Write-Host "=== 3. Create distribution folder ===" -ForegroundColor Cyan
$distDir = "dist\worship_slides"
if (Test-Path $distDir) { Remove-Item -Recurse -Force $distDir }
New-Item -ItemType Directory -Force -Path "$distDir\python" | Out-Null

Copy-Item -Recurse "build\windows\x64\runner\Release\*" "$distDir\"
Copy-Item "python\ppt_tool.exe" "$distDir\python\"
Copy-Item "python\ppt_tool.py" "$distDir\python\"
Copy-Item "python\requirements.txt" "$distDir\python\"

Write-Host "  -> Created $distDir" -ForegroundColor Green
Write-Host ""
Write-Host "Distribution layout:"
Get-ChildItem $distDir -Depth 2 | ForEach-Object { Write-Host $_.FullName }
