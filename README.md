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

- No build or test commands are required.
- `compose-agentsmd` regenerates `AGENTS.md` from the configured ruleset.

## Environment variables

- None.

## Release / deploy

- Not applicable. This repository is a workspace index and is not released as a package.
