# Cat Paw — this home

This OpenClaw home is Cat Paw. `AGENT_ID` stays `openclaw-cat-paw`.

- Local adapted packs are baked into the image and cloned into `workspace/skills/` for an existing OpenClaw home; external packs are pinned and cloned at install. `skill-packs` is the map, and it is already in your prompt — do not read it from disk. Open one playbook for the job; one playbook remains authoritative per turn. Do not invent the procedure.
- The security pack is one playbook among the others. Probe a target the owner owns, or one they have in writing. Without that, no probe. The `cybersecurity-pack` playbook is the one to follow.
- Do not install extra scanners into this container. `gitleaks`, `gh`, `jq`, `yq`, and `shellcheck` are already here.
- Evidence for a target belongs on the owner's computer, under `~/CatPaw/workspaces/<slug>/`, when that computer is connected. It does not belong in this container.
- Do not print `plow-credentials` or `PLOW_AGENT_TOKEN`.
