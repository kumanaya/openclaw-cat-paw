# Confirm the Compose agent reports as openclaw-cat-paw, that the base finished
# a boot against the Plow line, and that the playbook packs are on disk AND
# loaded by OpenClaw.
#
# Always exec the Index client as uid node - docker compose exec defaults to
# root, and a root-owned ledger under the state volume cannot be updated by the
# five-minute reporter.
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$ComposeFile = Join-Path $Root "compose.yml"
$Service = "openclaw-cat-paw"
$AgentId = "openclaw-cat-paw"
$Python = "python3"
$Client = "/opt/plow/agent-index-client.py"

# Container paths. State is the OpenClaw state directory the base itself
# exports; Baked is the image's own skills directory, which the base registers
# as skills.load.extraDirs so a pack there needs no config to be found.
$State = "/var/lib/plow"
$Config = "$State/openclaw.json"
$BootLog = "$State/boot.log"
$Baked = "/opt/plow/skills"
$Runtime = "$State/workspace/skills"

function Invoke-Compose {
    docker compose -f $ComposeFile @args
    if ($LASTEXITCODE -ne 0) { throw "docker compose failed: $args" }
}

function Get-SkillCount([string]$Path) {
    $output = @(docker compose -f $ComposeFile exec -T -u node $Service sh -c "find '$Path' -name SKILL.md -type f 2>/dev/null | wc -l")
    $text = ($output -join "").Trim()
    $count = 0
    if (-not [int]::TryParse($text, [ref]$count)) { return 0 }
    return $count
}

$id = docker compose -f $ComposeFile ps -q $Service 2>$null
if (-not $id) {
    throw "verify: container is not running. Start it with scripts/install.ps1."
}

Write-Host "verify: repairing Agent Index ledger ownership under $State"
Invoke-Compose exec -T -u 0 $Service sh -c @'
  for f in /var/lib/plow/.agent-index.json \
           /var/lib/plow/.agent-index.json.new \
           /var/lib/plow/.agent-index.lock \
           /var/lib/plow/.agent-index; do
    [ -e "$f" ] || continue
    chown -R node:node "$f"
  done
  got=$(printenv AGENT_ID || true)
  echo "verify: container AGENT_ID=${got:-<unset>}"
  if [ "$got" != "openclaw-cat-paw" ]; then
    echo "verify: AGENT_ID must be openclaw-cat-paw and must not be inherited from the host" >&2
    exit 1
  fi
'@

# The base renders its own OpenClaw configuration during boot, and a cold first
# boot resolves the model provider first. Being "up" is not the same as having
# rendered, and this wait is a real dependency.
Write-Host "verify: waiting for the base to render $Config"
$rendered = $false
for ($attempt = 1; $attempt -le 90; $attempt++) {
    docker compose -f $ComposeFile exec -T -u node $Service test -s $Config 2>$null
    if ($LASTEXITCODE -eq 0) { $rendered = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $rendered) {
    throw ("verify: the base did not render $Config within 180s. That file is the base's own " +
        "configuration, so this is a boot that did not finish. docker compose logs $Service")
}
Write-Host "verify: $Config rendered"

# The one line the base prints when the Plow line authenticated. A boot fact, not
# a live socket probe: the base has no channel status file to read from outside
# the Gateway. A reply from the line is the real proof.
$identity = (docker compose -f $ComposeFile exec -T -u node $Service sh -c `
        "grep -o 'identity resolved to .*' '$BootLog' 2>/dev/null | tail -n 1") -join ""
$identity = $identity.Trim()
if ($identity) {
    Write-Host "verify: plow-boot: $identity"
} else {
    Write-Host "verify: no 'identity resolved to' line in $BootLog yet."
    Write-Host "verify: the line has not authenticated. Check: docker compose logs $Service"
}

# The base already runs this reporter every five minutes as long as AGENT_ID is
# set. This is the same client, run once, as the user that owns the ledger.
function Invoke-IndexClient {
    docker compose -f $ComposeFile exec -T -u node `
        -e HOME=$State `
        -e OPENCLAW_STATE_DIR=$State `
        -e AGENT_ID=$AgentId `
        $Service $Python $Client @args
}

Write-Host "verify: Agent Index client as uid node (never root)"
Write-Host "verify: --self-check uses throwaway /tmp dirs; 'unreadable' there is expected."
Invoke-IndexClient --self-check
if ($LASTEXITCODE -ne 0) { throw "verify: --self-check failed" }
Invoke-IndexClient status
$status = $LASTEXITCODE
Write-Host "verify: status exit $status (0=registered, 3=unregistered)"
if ($status -eq 3) {
    Write-Host "verify: not registered yet - registering now (do not wait for the 5-minute loop)"
    # PLOW_API_BASE and PLOW_AGENT_TOKEN are already in this container's
    # environment, from plow-credentials. They are read in there; the token is
    # never pulled across to this shell and never printed.
    Invoke-IndexClient --register --agent $AgentId `
        --name "OpenClaw Cat Paw" `
        --blurb "Text the cat. It picks a playbook and does the job." `
        --runtime "OpenClaw / Plow Chat" `
        --repo "https://github.com/kumanaya/openclaw-cat-paw" `
        --install-url "https://github.com/kumanaya/openclaw-cat-paw/blob/main/docs/INSTALL.md" `
        --video "KjWFtHh0EFE" `
        --image "https://raw.githubusercontent.com/kumanaya/openclaw-cat-paw/main/docs/agent-index/hackathon-banner.png" `
        --image "https://raw.githubusercontent.com/kumanaya/openclaw-cat-paw/main/docs/agent-index/hackathon-cat-paw-latch.png"
    if ($LASTEXITCODE -eq 0) {
        Invoke-IndexClient status
        $status = $LASTEXITCODE
    }
}
if ($status -ne 0 -and $status -ne 3) { throw "verify: Agent Index status failed ($status)" }
Invoke-IndexClient --agent $AgentId --dry-run
if ($LASTEXITCODE -ne 0) { throw "verify: --dry-run failed" }

Write-Host "verify: reporting current usage as node"
Invoke-IndexClient --agent $AgentId
if ($LASTEXITCODE -ne 0) { throw "verify: live report failed. Check docker compose logs $Service" }

Write-Host "verify: baked playbooks ($Baked)"
# Every SKILL.md in this repository must be a TOP-LEVEL directory in the image.
# image/publish-skills.sh flattens the repo's `skills/<pack>/<playbook>/` shape
# at build time, because OpenClaw's loader stops at a directory that has a
# SKILL.md and never looks inside it - a pack baked as-is loads its router and
# none of the playbooks behind it.
$expectedNames = @(
    Get-ChildItem (Join-Path $Root "skills") -Filter SKILL.md -Recurse -File |
        ForEach-Object { $_.Directory.Name } | Sort-Object
)
$expected = $expectedNames.Count
$missing = 0
foreach ($name in $expectedNames) {
    docker compose -f $ComposeFile exec -T -u node $Service test -f "$Baked/$name/SKILL.md" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "verify: $name is not a top-level skill in the image."
        $missing++
    }
}
if ($missing -ne 0) { throw "verify: $missing of $expected playbooks are missing or still nested. Rebuild (scripts/install.ps1)." }
Write-Host "verify: $expected/$expected playbooks are top-level skills in the image"

Write-Host "verify: OpenClaw actually loads them (not just on disk)"
# Files in a skills directory prove a copy landed. They do not prove the loader
# sees them, and a playbook the model cannot open is a playbook the cat does
# not have. This asks OpenClaw itself, and requires every one of them to be
# model-visible.
$wantedCsv = $expectedNames -join ","
$listed = docker compose -f $ComposeFile exec -T -u node $Service $Python -c @'
import json, subprocess, sys
listed = subprocess.run(["openclaw", "skills", "list", "--json"],
                        capture_output=True, text=True)
if listed.returncode != 0:
    print("SKILLS-UNAVAILABLE")
    sys.exit(0)
data = json.loads(listed.stdout)
wanted = {name for name in sys.argv[1].split(",") if name}
names = {skill["name"] for skill in data.get("skills", []) if skill.get("modelVisible")}
print(",".join(sorted(names & wanted)) or "NONE")
'@ $wantedCsv 2>$null
$visible = (($listed -join "").Trim() -split "`n")[-1].Trim()
if (-not $visible -or $visible -eq "SKILLS-UNAVAILABLE") {
    throw "verify: could not read the loaded skill list. Check: docker compose exec $Service openclaw skills list"
}
if ($visible -eq "NONE") {
    throw "verify: OpenClaw sees none of the Cat Paw skills. The extraDirs the base registers is $Baked."
}
$seen = @($visible -split "," | Where-Object { $_ }).Count
if ($seen -ne $expected) {
    throw ("verify: OpenClaw loads $seen of $expected playbooks. The rest are on disk but not " +
        "model-visible. docker compose exec $Service openclaw skills check")
}
Write-Host "verify: OpenClaw loads all $seen playbooks as model-visible"

Write-Host "verify: runtime-cloned packs ($Runtime)"
$pack = Get-SkillCount "$Runtime/cybersecurity-skills"
Write-Host "verify: cybersecurity-skills pack=$pack (run scripts/install-skills.ps1 if this is 0)"

foreach ($extra in @("engineering/mattpocock", "engineering/addyosmani", "engineering/alirezarezvani", "product", "marketing", "content", "sales", "finance", "customer-success", "design/emilkowalski", "design/ui-skills", "academic-research")) {
    $count = Get-SkillCount "$Runtime/$extra"
    Write-Host "verify: $extra=$count"
}

Write-Host "verify: baked review CLIs"
docker compose -f $ComposeFile exec -T -u node $Service /opt/cat-paw/verify-review-tools.sh
if ($LASTEXITCODE -ne 0) { throw "verify: review CLIs missing. Rebuild the image (scripts/install.ps1)." }

if ($status -eq 0) {
    Write-Host "verify: container OK, usage heartbeat signed in."
    Write-Host "verify: days=0 / tokens=0 is normal before a real chat."
} else {
    Write-Host "verify: container OK, usage heartbeat not signed in yet. It retries on its own. This is not a failed install."
}
Write-Host "verify: a reply from the line is the only proof the phone line is live. Text it now."
Write-Host "verify: do not docker compose exec the Agent Index client as root; use this script or -u node."
try {
    & (Join-Path $PSScriptRoot "announce-line.ps1")
} catch {
    Write-Host "verify: could not name the line. Do not make the owner guess."
}
