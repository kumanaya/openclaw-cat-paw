$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$LatchDir = if ($env:LATCH_DIR) { $env:LATCH_DIR } else { Join-Path (Split-Path -Parent $Root) "cat-paw-latch" }
$LatchRepo = if ($env:LATCH_REPO) { $env:LATCH_REPO } else { "https://github.com/kumanaya/cat-paw-latch.git" }

function Need([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing '$Name'. Install Git, Node.js 22+, npm, Python 3, just, and Visual Studio Build Tools (Desktop C++)."
    }
}

Need git
Need just
Need node
Need npm
Need python

$nodeMajor = [int]((node -v).TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 22) { throw "Node.js 22 or newer is required (found $(node -v))." }

if (-not (Test-Path -LiteralPath (Join-Path $LatchDir ".git"))) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LatchDir) | Out-Null
    git clone $LatchRepo $LatchDir
}

Push-Location $LatchDir
try {
    just install
} finally {
    Pop-Location
}

Write-Host "Cat Paw Latch is ready at $LatchDir"
$starter = Join-Path $PSScriptRoot "start-latch.ps1"
try {
    & $starter
} catch {
    Write-Host "Could not auto-launch Latch. In a visible terminal:"
    Write-Host "  cd $LatchDir"
    Write-Host "  just app"
}

Write-Host ""
Write-Host "Sign in, keep the approval window visible, then continue the agent setup with scripts/install.ps1. That installer mints a free line (or -Line NAME) and always starts Compose as AGENT_ID=openclaw-cat-paw."
