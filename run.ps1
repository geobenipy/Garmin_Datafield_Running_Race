<#
    run.ps1 - Compile the Running_Race data field and launch it in the
              Connect IQ simulator, in one step.

    Usage (from the Running_Race project folder):
        .\run.ps1                    # build + launch on fenix843mm
        .\run.ps1 -Device fr965      # build + launch on a different device
        .\run.ps1 -BuildOnly         # compile only, do not open the simulator

    Works even if the SDK bin folder is not on your PATH: it falls back to the
    SDK the Connect IQ SDK Manager currently points at.
#>
[CmdletBinding()]
param(
    [string]$Device    = "fenix843mm",
    [string]$Key       = "developer_key_pkcs8.der",
    [string]$Out       = "bin\Running_Race.prg",
    [string]$Jungle    = "monkey.jungle",
    [switch]$BuildOnly
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

# --- Locate the SDK bin folder -----------------------------------------------
function Get-SdkBin {
    # 1) Prefer whatever is already on PATH.
    $mc = Get-Command monkeyc.bat -ErrorAction SilentlyContinue
    if ($mc) { return (Split-Path $mc.Source) }
    # 2) Fall back to the SDK the SDK Manager currently points at.
    $cfg = Join-Path $env:APPDATA "Garmin\ConnectIQ\current-sdk.cfg"
    if (Test-Path $cfg) {
        $sdk = (Get-Content $cfg -Raw).Trim()
        $bin = Join-Path $sdk "bin"
        if (Test-Path $bin) { return $bin }
    }
    throw "Could not find the Connect IQ SDK bin folder. Is the SDK installed via the SDK Manager?"
}

$bin       = Get-SdkBin
$monkeyc   = Join-Path $bin "monkeyc.bat"
$connectiq = Join-Path $bin "connectiq.bat"
$monkeydo  = Join-Path $bin "monkeydo.bat"

Write-Host "SDK bin : $bin" -ForegroundColor DarkGray

# --- Compile ------------------------------------------------------------------
if (-not (Test-Path $Key)) { throw "Signing key not found: $Key" }
$outDir = Split-Path $Out
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

Write-Host "Building $Out for $Device ..." -ForegroundColor Cyan
& $monkeyc -f $Jungle -o $Out -y $Key -d $Device -w
if ($LASTEXITCODE -ne 0) { throw "Build failed (exit $LASTEXITCODE)." }
Write-Host "Build OK." -ForegroundColor Green

if ($BuildOnly) { return }

# --- Make sure the simulator is running --------------------------------------
if (-not (Get-Process -Name simulator -ErrorAction SilentlyContinue)) {
    Write-Host "Starting Connect IQ simulator ..." -ForegroundColor Cyan
    Start-Process -FilePath $connectiq
    # Wait for the simulator process to appear, then give it a moment to be
    # ready to accept a connection from monkeydo.
    for ($i = 0; $i -lt 30 -and -not (Get-Process -Name simulator -ErrorAction SilentlyContinue); $i++) {
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 2
} else {
    Write-Host "Simulator already running." -ForegroundColor DarkGray
}

# --- Load the app into the simulator -----------------------------------------
Write-Host "Loading app into simulator ..." -ForegroundColor Cyan
& $monkeydo $Out $Device
