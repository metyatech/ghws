# ghws workspace

This repository is a lightweight workspace index for managing the user's GitHub repositories. It stores the shared agent rules configuration and local workspace rules, and avoids tracking the actual project repositories.

## Setup

- Clone this repository.
- Run `compose-agentsmd` from the repository root to regenerate `AGENTS.md` when rules change.

## Autonomous operations

- Use the "Agent request" issue template in any repository to request end-to-end work.
- Provide the goal, scope, and constraints so the agent can execute without follow-ups.
- The default control plane is GitHub Issues/PR comments; other channels should be added only if a repository requires them.
- Organization-wide community health files live in the `.github` repository.

## Development commands

- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/setup-hooks.ps1` configures git hooks.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/lint.ps1` validates the ruleset JSON.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1` checks the documented automation link.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1` regenerates `AGENTS.md`.
- `compose-agentsmd` regenerates `AGENTS.md` from the configured ruleset.

## AI agent session launcher (Windows + WSL tmux)

- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-agent-session-launcher-shortcuts.ps1` creates Desktop and Start Menu shortcuts.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/agent-session-launcher.ps1` opens a GUI with buttons for Codex, Claude, Gemini, and Shell tmux sessions.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/agent-session-launcher.ps1 -Mode codex` launches one profile directly without opening the GUI.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/wsl-tmux.ps1 -SessionName shell-main` attaches or creates a named tmux session in WSL.
- `wsl.exe -d Ubuntu -- bash -lc 'cd /path/to/ghws && ./scripts/install-wsl-mobile-menu-hook.sh'` installs the mobile Termius auto-menu hook in `~/.bashrc`.
- Smartphone access uses `Termius` to SSH into the Windows host; successful SSH logins auto-open the mobile session menu in WSL.

## Environment variables

- None.

## Release / deploy

- Not applicable. This repository is a workspace index and is not released as a package.

## Overview
This repository contains the ghws project.

