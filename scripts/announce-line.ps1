# Print the dashboard name and phone number for this checkout's credential.
# Installing agents must relay both to the owner in the same turn.
# Never print tokens or plow-credentials.
param(
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
    Write-Host "Usage: announce-line.ps1"
    Write-Host "Prints the Plow line this agent is on (dashboard name + phone number)."
    return
}

$Root = Split-Path -Parent $PSScriptRoot
$Credentials = Join-Path $Root "plow-credentials"
$Tools = Join-Path $Root ".tools\plow-agents"
$Cli = Join-Path $Tools "bin\plow-agents"
$TokenHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME ".config" }
$TokenFile = Join-Path $TokenHome "plow\token"

if (-not (Test-Path -LiteralPath $Credentials -PathType Leaf)) {
    Write-Error "announce-line: no plow-credentials file. The line is not signed in. Tell the owner the install is not done. Re-run scripts/install.ps1."
}

$uid = $null
foreach ($line in Get-Content -LiteralPath $Credentials) {
    if ($line -match '^# plow-agent-uid:\s*(.+)$') {
        $uid = $Matches[1].Trim()
        break
    }
}
if (-not $uid) {
    Write-Error "announce-line: plow-credentials has no # plow-agent-uid comment. Tell the owner you could not name the line. Do not guess."
}

if (-not ((Test-Path -LiteralPath $TokenFile -PathType Leaf) -and ((Get-Item -LiteralPath $TokenFile).Length -gt 0))) {
    Write-Error "announce-line: no Plow account token. Tell the owner you could not name the line. Do not guess."
}

if (-not (Test-Path -LiteralPath (Join-Path $Tools ".git"))) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Tools) | Out-Null
    git clone https://github.com/plow-pbc/plow-agents.git $Tools
    if ($LASTEXITCODE -ne 0) { throw "git clone plow-agents failed" }
}

$matched = $false
foreach ($raw in python $Cli lines) {
    $text = "$raw"
    if ($text -notmatch "`t") { continue }
    $parts = $text -split "`t", 4
    if ($parts.Count -lt 4) { continue }
    if ($parts[0] -eq "LINE") { continue }
    if ($parts[3] -ne $uid) { continue }
    Write-Host "announce-line: dashboard name: $($parts[1])"
    Write-Host "announce-line: text this number: $($parts[2])"
    Write-Host "announce-line: tell the owner both in this turn. They text that number. Do not make them guess."
    $matched = $true
    break
}

if (-not $matched) {
    Write-Error "announce-line: this credential did not match a dashboard line. Tell the owner you could not name the line. Do not guess. Run plow-agents lines and match STATUS to the credential uid. Never print the token."
}
