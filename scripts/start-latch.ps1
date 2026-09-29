$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$LatchDir = if ($env:LATCH_DIR) { $env:LATCH_DIR } else { Join-Path (Split-Path -Parent $Root) "cat-paw-latch" }

function Test-LatchRunning {
    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "PlowLatch|electron" -and $_.CommandLine -match "Plow-Latch|PlowLatch|@domo/desktop"
    }
    return [bool]$procs
}

if (Test-LatchRunning) {
    Write-Host "Plow Latch is already running. Leave the approval window visible."
    exit 0
}

if (-not (Test-Path -LiteralPath $LatchDir)) {
    throw "Latch is not installed. Run scripts/setup-latch.ps1 first."
}

Write-Host "Launching Cat Paw Latch from $LatchDir"
Start-Process -FilePath "just" -ArgumentList "app" -WorkingDirectory $LatchDir

$n = 0
while ($n -lt 20) {
    if (Test-LatchRunning) {
        Write-Host "Plow Latch is running. Sign in if this is the first launch and leave the approval window visible."
        exit 0
    }
    $n++
    Start-Sleep -Seconds 1
}

throw "Latch did not stay up. From $LatchDir run: just app"
