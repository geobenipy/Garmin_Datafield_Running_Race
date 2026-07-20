<#
    run.ps1 - Compile the Running_Race data field and launch it in the
              Connect IQ simulator, in one step.

    Usage (from the Running_Race project folder):
        .\run.ps1                    # build + launch on fenix843mm
        .\run.ps1 -Device fr965      # build + launch on a different device
        .\run.ps1 -BuildOnly         # compile only, do not open the simulator
        .\run.ps1 -Shot              # build + launch + save a PNG screenshot
        .\run.ps1 -Shot -ShotPath x  # ...write the screenshot to path x

    -Shot captures the simulator window to bin\sim_shot.png (gitignored) so the
    rendered result can be inspected without a manual screenshot.

    Works even if the SDK bin folder is not on your PATH: it falls back to the
    SDK the Connect IQ SDK Manager currently points at.
#>
[CmdletBinding()]
param(
    [string]$Device    = "fenix843mm",
    [string]$Key       = "developer_key_pkcs8.der",
    [string]$Out       = "bin\Running_Race.prg",
    [string]$Jungle    = "monkey.jungle",
    [switch]$BuildOnly,
    [switch]$Shot,
    [string]$ShotPath  = "bin\sim_shot.png"
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

# --- Capture the simulator window to a PNG -----------------------------------
function Save-SimShot {
    param([string]$Path)
    if (-not ([System.Management.Automation.PSTypeName]'WinCap').Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WinCap {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int n);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
    }
    [WinCap]::SetProcessDPIAware() | Out-Null

    # Wait for the simulator window to exist.
    $h = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $p = Get-Process simulator -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($p) { $h = $p.MainWindowHandle; break }
        Start-Sleep -Milliseconds 700
    }
    if ($h -eq [IntPtr]::Zero) { Write-Host "Shot: simulator window not found."; return }

    if ([WinCap]::IsIconic($h)) { [WinCap]::ShowWindow($h, 9) | Out-Null }  # SW_RESTORE
    [WinCap]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 600

    $r = New-Object 'WinCap+RECT'
    [WinCap]::GetWindowRect($h, [ref]$r) | Out-Null
    $w  = $r.Right - $r.Left
    $ht = $r.Bottom - $r.Top
    if ($w -le 0 -or $ht -le 0) { Write-Host "Shot: bad window rect."; return }

    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)

    $full = [System.IO.Path]::GetFullPath($Path)
    $dir  = Split-Path $full
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "Shot saved: $full (${w}x${ht})" -ForegroundColor Green
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
    for ($i = 0; $i -lt 30 -and -not (Get-Process -Name simulator -ErrorAction SilentlyContinue); $i++) {
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 2
} else {
    Write-Host "Simulator already running." -ForegroundColor DarkGray
}

# --- Load the app into the simulator -----------------------------------------
Write-Host "Loading app into simulator ..." -ForegroundColor Cyan
if ($Shot) {
    # Detached so this script can continue on to capture the rendered screen.
    Start-Process -FilePath $monkeydo -ArgumentList $Out, $Device `
                  -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 4     # let the app get pushed and drawn
    Save-SimShot -Path $ShotPath
} else {
    & $monkeydo $Out $Device
}
