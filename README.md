# ghws workspace

`ghws` is the lightweight index and rules root for the user's multi-repository GitHub workspace. The actual product repositories live as sibling directories under the workspace root.

This repository keeps:

- the composed agent rules configuration for the workspace
- the local workspace-specific rule module
- lightweight workspace bootstrap and verification scripts

The cross-device AI agent session fabric now lives in the sibling repository `workspace-agent-hub`, not in this root repository.

## Setup

- Clone this repository into the workspace root.
- Run `compose-agentsmd` from the repository root when rules change.
- Run `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/setup-hooks.ps1` to configure local git hooks.

## One-click update

**Double-click in Explorer**: `pull-all.cmd` at the workspace root.
The window stays open after completion so you can read the summary, then press any key to close it.

**PowerShell terminal**:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/pull-all.ps1
```

Both paths invoke the same `scripts/pull-all.ps1` implementation.
The script checks the workspace root itself plus each direct child directory of the workspace root for standalone Git repositories, then runs `git pull` on each one and prints a per-repo status summary.
Each repository is identified by its workspace-relative path and full absolute path in both the per-repo progress output and the final summary (for example, `workspace-agent-hub  OK  [C:\ghws\workspace-agent-hub]`).
Submodules (`.git` is a file) are detected and skipped automatically; the skip and summary lines include the relative path. Repositories whose current branch has no upstream are reported as `NOTE (no upstream)` and do not fail the overall run. Repositories whose local changes block a pull are still treated as failures. Transient/inaccessible direct child directories are suppressed from the live output and summarized once instead of spamming errors. Non-git directories are silently ignored. If any repository fails to pull, it is reported and the script exits with code 1 after finishing all others.
`pull-all.cmd` propagates the same exit code.

## Workspace tools

- `workspace-agent-hub`: Windows + WSL `tmux` session fabric for AI agent CLI handoff across PC and smartphone. GitHub: `https://github.com/metyatech/workspace-agent-hub`

## Development commands

- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/lint.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1`
- `compose-agentsmd`

## Environment variables

- None.

## Release / deploy

- Not applicable. This repository is a workspace index and rules root, not a publishable package.

## Links

- [CHANGELOG.md](CHANGELOG.md)
- [SECURITY.md](SECURITY.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)
- [LICENSE](LICENSE)
