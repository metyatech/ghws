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
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1` runs the shell/mobile regression suite. Set `GHWS_RUN_ANDROID_MOBILE_E2E=1` to add the emulator-backed mobile SSH check.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1` regenerates `AGENTS.md`.
- `compose-agentsmd` regenerates `AGENTS.md` from the configured ruleset.

## AI agent session launcher (Windows + WSL tmux)

- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-agent-session-launcher-shortcuts.ps1` creates Desktop and Start Menu shortcuts.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/agent-session-launcher.ps1` opens `AI Agent Hub`, which can start new sessions, reopen running sessions, rename titles, archive/unarchive, close, and delete sessions.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/agent-session-launcher.ps1 -Mode codex` launches one profile directly without opening the GUI.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/agent-session-launcher.ps1 -Mode list -Json -IncludeArchived` prints the full session inventory, including archived or closed entries.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/agent-session-launcher.ps1 -Mode rename -SessionName shell-example -Title "Current debugging task"` updates the human-facing title for an existing session.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/agent-session-launcher.ps1 -Mode archive -SessionName shell-example` hides a session from the default resume list without killing it.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/agent-session-launcher.ps1 -Mode close -SessionName shell-example` kills the running tmux session and keeps it as a closed archived entry.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/agent-session-launcher.ps1 -Mode delete -SessionName shell-example` removes the session entry entirely and kills the tmux session if it is still running.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/wsl-tmux.ps1 -SessionName shell-main` attaches or creates a named tmux session in WSL.
- `wsl.exe -d Ubuntu -- bash -lc 'cd /path/to/ghws && ./scripts/install-wsl-mobile-menu-hook.sh'` installs the mobile Termius auto-menu hook in `~/.bashrc`.
- Smartphone access uses `Termius` to SSH into the Windows host; successful SSH logins auto-open the mobile session menu in WSL.
- `wsl.exe -d Ubuntu -- bash -lc 'cd /path/to/ghws && ./scripts/wsl-agent-mobile-menu.sh list-all'` shows archived and closed entries from the mobile-side CLI.
- `wsl.exe -d Ubuntu -- bash -lc 'cd /path/to/ghws && ./scripts/wsl-agent-mobile-menu.sh manage'` opens the mobile management flow for rename/archive/close/delete without using the Windows GUI.
- `python scripts/test-android-mobile-e2e.py` boots an Android emulator, installs ConnectBot if needed, connects to a temporary WSL `sshd`, and checks whether the Android SSH client can authenticate and auto-attach to a prepared tmux session. The script exits non-zero when it reproduces the current ConnectBot disconnect limitation.
- `GHWS_RUN_ANDROID_MOBILE_E2E=1 powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1` adds the emulator-backed mobile E2E to the normal regression suite.

### Primary path matrix

This session fabric claims the following primary handoff paths and ties each one to automated verification in the repo-standard test suite.

| Path | Claimed behavior | Automated evidence |
| --- | --- | --- |
| `P1` | PC-side launcher flow can create a session, surface it in the inventory, and resolve it again for reopening. | `scripts/test-primary-path-matrix.ps1` creates launcher-managed shell sessions, verifies title/folder metadata in `agent-session-launcher.ps1 -Mode list -Json`, and checks `-Mode resume -Detach` availability. |
| `P2` | A session started from the PC side can be reopened from the mobile SSH menu. | `scripts/test-mobile-ssh.py` creates a launcher-managed shell session, enters the mobile menu over a temporary SSH path, selects the matching title/folder, and verifies that the session opens in the expected working directory before the SSH client disconnects. |
| `P3` | A session started from the mobile SSH menu becomes visible and reopenable from the PC-side launcher flow. | `scripts/test-mobile-ssh.py` starts a shell session through the mobile menu, verifies that it opens in the requested working directory, then checks launcher inventory metadata and `-Mode resume -Detach` on the PC side. |
| `P4` | When multiple sessions exist, the user can distinguish and reopen the intended one by title/folder. | `scripts/test-primary-path-matrix.ps1` verifies distinct launcher inventory entries on the PC side, and `scripts/test-mobile-ssh.py` verifies mobile-menu selection of the intended session among multiple active entries. |

Additional environment notes:

- `scripts/test-mobile-ssh.py` uses a temporary Windows `sshd` plus the WSL mobile-menu bootstrap as the least-cost faithful automated boundary for the mobile control path.
- `python scripts/test-android-mobile-e2e.py` covers an Android emulator plus ConnectBot separately and currently reproduces a known limitation: ConnectBot authenticates and starts the session, then disconnects before `tmux attach`.

## Environment variables

- None.

## Release / deploy

- Not applicable. This repository is a workspace index and is not released as a package.

## Overview
This repository contains the ghws project.

