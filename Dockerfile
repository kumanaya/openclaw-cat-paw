# OpenClaw Cat Paw on Plow's maintained OpenClaw base image.
#
# The base owns the boot, the Plow channel plugin, the Latch MCP bridge, the
# OpenClaw gateway config and the usage reporter. This image owns the persona
# and the playbook packs. Every line we do not write is a boot fix inherited
# free on the next base bump.
#
# Pinned by digest as well as tag, like the base itself: a tag is a name
# somebody can move, and the code it names boots holding this agent's live Plow
# credential. The tag names the plow-openclaw-agent commit the image was
# published from; the digest is that image's manifest. Bump both together.
# Ref: https://github.com/plow-pbc/plow-openclaw-agent
FROM public.ecr.aws/e1h7x4a2/plow-cloud-agents:base-d78e4ea75e7c44b9b63d7ea4b50b2aa180daf51f@sha256:f687b5eb54153edcf143deeef52c66465a19efb5e371b03f054465f5e46337f7

# Agent Index identity. The base's own reporter reads AGENT_ID every five
# minutes and stands down entirely when it is unset, so an owner who does not
# want their usage on the Index builds without it. AGENT_NAME and AGENT_BLURB
# are sent once, on registration: the Index leaves a field it is not given
# alone, so a value passed every pass would overwrite an edit the owner made
# on their own page. Edit the page on the Index, not here.
ENV AGENT_ID=openclaw-cat-paw
ENV AGENT_NAME="OpenClaw Cat Paw"
ENV AGENT_BLURB="OpenClaw Cat Paw, a builder cat you text from your phone. It opens one playbook per job and works that objective instead of improvising a procedure, and reaches your computer through Latch when you want to approve an action before it runs."

# The model is `plow/z-ai/glm-5.2`, with `plow/anthropic/claude-sonnet-5` as
# the fallback. That is a decision, so it is written down, and it is the
# model's job to enforce rather than this file's.
#
# Nothing is set here on purpose. The base renders the provider list and
# `agents.defaults.model` into the config it owns, and an id outside that list
# is refused at the provider — so an override here would be a second place
# that can disagree with the first. scripts/verify.sh reads the effective model
# out of the running agent and fails if a base bump moves it, which is the
# only way this choice can be broken silently. Change it with
# `openclaw config patch` against `agents.defaults.model`, not here.
#
# AGENT_RUNTIME is likewise the base's to set: it already reports OpenClaw.

# Tiny review CLIs (gitleaks, gh, jq, yq, shellcheck). No Semgrep/Trivy/nmap —
# those bloat the image. Live probes stay on Latch. External playbooks clone at
# install time; local adapted packs are baked here.
#
# /opt/plow and / are root-owned and the image runs as `node`, so this is the
# one step that needs root. `USER node` returns below, and it has to be the
# LAST `USER` line in this file: left as the final directive it also becomes the
# user the container RUNS as, which ships the deployment privileged.
USER root

COPY vendor/review-tools.pin /opt/cat-paw/review-tools.pin
COPY image/install-review-tools.sh image/verify-review-tools.sh /opt/cat-paw/
RUN chmod 0755 /opt/cat-paw/install-review-tools.sh /opt/cat-paw/verify-review-tools.sh \
 && /opt/cat-paw/install-review-tools.sh \
 && /opt/cat-paw/verify-review-tools.sh

# Identity specific to this agent. The base's boot reads /opt/plow/prompt/AGENTS.md
# on every start and renders it into /var/lib/plow/workspace/AGENTS.md, with the
# Latch instructions block appended when a Mac is connected. The source file is
# PERSONA.md. Do not COPY an AGENTS.md into the state volume: the volume masks
# the image layer and the next boot overwrites it anyway.
COPY PERSONA.md /opt/plow/prompt/AGENTS.md
RUN chmod 0644 /opt/plow/prompt/AGENTS.md

# ── the playbooks ─────────────────────────────────────────────────────────────
# Two sources, and the order matters.
#
# First the shared ones, from cat-paw-workflows at the commit pinned in
# vendor/cat-paw-workflows.pin. The Dockerfile reads sha= out of that file
# rather than taking an ARG, so there is one place to bump and no way for the
# pin and the build to disagree — which is the failure a two-place pin always
# eventually has.
#
# `--filter=blob:none` with a full clone, not --depth 1: the pin is a commit and
# a shallow clone cannot reach one that is not a branch tip. The clone is
# removed in the same layer it was made in.
ARG CAT_PAW_WORKFLOWS_PIN=vendor/cat-paw-workflows.pin
COPY vendor/cat-paw-workflows.pin ${CAT_PAW_WORKFLOWS_PIN}
RUN set -eu; \
    pin="${CAT_PAW_WORKFLOWS_PIN}"; \
    repo="$(sed -n 's/^repo=//p' "$pin")"; \
    sha="$(sed -n 's/^sha=//p' "$pin")"; \
    [ -n "$repo" ] && [ -n "$sha" ] || { echo "cat-paw-workflows: malformed $pin" >&2; exit 1; }; \
    git clone --filter=blob:none "$repo" /tmp/cat-paw-workflows; \
    git -C /tmp/cat-paw-workflows checkout --quiet "$sha"; \
    got="$(git -C /tmp/cat-paw-workflows rev-parse HEAD)"; \
    [ "$got" = "$sha" ] || { echo "cat-paw-workflows: wanted $sha, got $got" >&2; exit 1; }; \
    # Trailing slashes on both sides: contents of skills/ merge into the tree
    # the base already put at /opt/plow/skills, so we inherit the base's
    # `owners-mac`, `google-workspace`, `knowledge-base` and `support-desk` and
    # add ours beside them.
    cp -a /tmp/cat-paw-workflows/skills/. /opt/plow/skills/; \
    cp -a /tmp/cat-paw-workflows/LICENSE /opt/plow/skills/LICENSE.cat-paw-workflows; \
    rm -rf /tmp/cat-paw-workflows

# Then the five skills that are statements about THIS agent: the boot, the
# state directory, how a reply is delivered, what is baked in this image. They
# cannot be shared because a shared text would be false in the other runtime.
# Same trailing-slash rule, same reason.
COPY skills/ /opt/plow/skills/

# /opt/plow/skills is already a configured skills source: the base renders
# `skills.load.extraDirs: ["/opt/plow/skills"]` into the configuration it owns.
# Nothing here has to register a path.
#
# Then flatten. OpenClaw's loader stops at a directory that has a SKILL.md, so
# the `skills/<pack>/<playbook>/SKILL.md` shape would load the ten routers and
# none of the thirty playbooks behind them. image/publish-skills.sh lifts each
# nested playbook to the top level, and fails the build rather than shipping a
# cat that advertises playbooks it cannot open. It also refuses on a name
# collision instead of letting one playbook shadow another.
COPY image/publish-skills.sh /opt/cat-paw/publish-skills.sh
RUN chmod 0755 /opt/cat-paw/publish-skills.sh \
 && /opt/cat-paw/publish-skills.sh /opt/plow/skills

COPY LICENSE /opt/plow/skills/LICENSE.openclaw-cat-paw

# Normalise modes without touching the owner of /opt/plow/skills, which is the
# base's. The runtime packs that scripts/install-skill-packs.sh clones land in
# /var/lib/plow/workspace/skills on the state volume instead, because that is
# the workspace skill root and it survives an image rebuild.
RUN find /opt/plow/skills -type d -exec chmod 0755 {} + \
 && find /opt/plow/skills -type f -exec chmod 0644 {} +

USER node
