# Contributing

Thanks for your interest in contributing to `ghws`.

## Scope

This repository is the workspace index and agent-rules composition root for the multi-repository `ghws` workspace. Feature implementation for workspace tools belongs in the relevant sibling repository, such as `workspace-agent-hub`.

## Workflow

- Create a branch (optional) or work on `main`.
- Update docs and rules together when behavior changes.
- Regenerate `AGENTS.md` by running `compose-agentsmd`.
- Commit with a clear message and open a PR if desired.
- Use `scripts/bootstrap-user-repo.ps1` to apply the standard high-quality workflow to user-controlled repositories under `ghws`.
- Use `scripts/audit-all.ps1` and `scripts/verify-all.ps1` to check drift across user-controlled repositories.

## Development commands

- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/setup-hooks.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/lint.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1`

## Testing

Run the full verification suite before each commit:

- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/lint.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1`
