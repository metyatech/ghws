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
