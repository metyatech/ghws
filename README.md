# ghws workspace

This repository is a lightweight workspace index for managing the user's GitHub repositories. It stores the shared agent rules configuration and local workspace rules, and avoids tracking the actual project repositories.

## Setup

- Clone this repository.
- Run `compose-agentsmd` from the repository root to regenerate `AGENTS.md` when rules change.

## Development commands

- No build or test commands are required.
- `compose-agentsmd` regenerates `AGENTS.md` from the configured ruleset.

## Environment variables

- None.

## Release / deploy

- Not applicable. This repository is a workspace index and is not released as a package.
