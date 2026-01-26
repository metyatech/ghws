# Contributing

Thanks for your interest in contributing to `ghws`.

## Scope

This repository is a lightweight workspace index. It stores shared agent rule configuration and local workspace rules, and intentionally avoids tracking the actual project repositories.

## Workflow

- Create a branch (optional) or work on `main`.
- Update or add rule files as needed.
- Regenerate `AGENTS.md` by running:
  - `compose-agentsmd`
- Commit with a clear message and open a PR if desired.

## Development commands

- `compose-agentsmd`

## Testing

There are no runtime tests. The CI workflow verifies that `AGENTS.md` is up to date by running `compose-agentsmd` and checking for diffs.
