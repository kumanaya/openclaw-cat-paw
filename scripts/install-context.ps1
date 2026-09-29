# Land Cat Paw context in an OpenClaw home.
#
# OpenClaw has no SOUL.md. The persona is the workspace's AGENTS.md, and it is
# the same file the project context lives in, so this script has one file to
# write, not two.
#
# On the Compose image the base's boot renders /opt/plow/prompt/AGENTS.md
# (copied from PERSONA.md here) into /var/lib/plow/workspace/AGENTS.md on every
# start. This script does NOT write that file in the container: the persona is
# already in the image and the next boot would overwrite anything written now.
#
# An existing OpenClaw (-Home) has no such boot, so the Cat Paw section is
# appended to <Home>/workspace/AGENTS.md, or refreshed in place if it is
# already there. The rest of that file is never touched. Only a missing
# AGENTS.md is created, and then it is created as the persona plus the section.
param(
    [Alias("Home")]
    [string]$HomeDir
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Persona = Join-Path $Root "PERSONA.md"
$Section = Join-Path $Root "context\AGENTS.section.md"
$ComposeFile = Join-Path $Root "compose.yml"
$Service = "openclaw-cat-paw"
$Begin = "<!-- cat-paw:agents -->"
$End = "<!-- /cat-paw:agents -->"
$Utf8 = New-Object System.Text.UTF8Encoding $false

function Read-Utf8([string]$Path) {
    return [System.IO.File]::ReadAllText($Path)
}

function Write-Utf8([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8)
}

function Get-MarkedSection {
    $body = Read-Utf8 $Section
    if (-not $body.EndsWith("`n")) { $body += "`n" }
    return "$Begin`n$body$End`n"
}

function Set-AgentsSection([string]$Path) {
    $block = Get-MarkedSection
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Utf8 $Path $block
        return
    }
    $text = Read-Utf8 $Path
    $start = $text.IndexOf($Begin)
    if ($start -lt 0) {
        if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`n" }
        if ($text.Length -gt 0) { $text += "`n" }
        $text += $block
    } else {
        $stop = $text.IndexOf($End, $start)
        if ($stop -lt 0) {
            $text = $text.Substring(0, $start) + $block
        } else {
            $after = $stop + $End.Length
            if ($after -lt $text.Length -and ($text[$after] -eq "`n" -or $text[$after] -eq "`r")) { $after++ }
            if ($after -lt $text.Length -and $text[$after] -eq "`n") { $after++ }
            $text = $text.Substring(0, $start) + $block + $text.Substring($after)
        }
    }
    Write-Utf8 $Path $text
}

function New-PersonaBlock {
    $persona = Read-Utf8 $Persona
    if (-not $persona.EndsWith("`n")) { $persona += "`n" }
    return $persona + "`n"
}


if (-not (Test-Path -LiteralPath $Persona) -or -not (Test-Path -LiteralPath $Section)) {
    throw "install-context.ps1: missing PERSONA.md or context section."
}

if ($HomeDir) {
    $workspace = Join-Path $HomeDir "workspace"
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    $agents = Join-Path $workspace "AGENTS.md"
    if (-not (Test-Path -LiteralPath $agents)) {
        Write-Utf8 $agents (New-PersonaBlock)
        Write-Host "install-context.ps1: wrote $agents from PERSONA.md"
    }
    Set-AgentsSection $agents
    Write-Host "install-context.ps1: Cat Paw section is in $agents"
    Write-Host "install-context.ps1: the rest of that file is untouched"
    return
}

$id = docker compose -f $ComposeFile ps -q $Service 2>$null
if (-not $id) {
    throw "install-context.ps1: Compose agent is not running. Start it with scripts/install.ps1, or pass -Home OPENCLAW_STATE_DIR."
}

# Confirm the fact rather than assert it. The boot owns this file; writing it
# here would be undone by the next start, so the only useful check is that the
# persona we baked is the one the boot is holding.
$workspaceAgents = "/var/lib/plow/workspace/AGENTS.md"
$carries = docker compose -f $ComposeFile exec -T -u node $Service sh -c `
    "grep -c 'chaotic builder cat' '$workspaceAgents' 2>/dev/null || true"
if ([int](($carries -join "").Trim() -replace "[^0-9]", "") -lt 1) {
    throw ("install-context.ps1: $workspaceAgents has no Cat Paw persona. That file is written by " +
        "the base's boot from the image's prompt. Rebuild the image (scripts/install.ps1) and " +
        "check: docker compose logs $Service")
}

Write-Host "install-context.ps1: $workspaceAgents carries the Cat Paw persona"
Write-Host "install-context.ps1: rendered on every boot from /opt/plow/prompt/AGENTS.md"
