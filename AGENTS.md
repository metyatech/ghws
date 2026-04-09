<!-- markdownlint-disable MD025 -->
# Tool Rules (compose-agentsmd)

- **Session gate**: before responding to ANY user message, run `compose-agentsmd` from the project root. AGENTS.md contains the rules you operate under; stale rules cause rule violations. If you discover you skipped this step mid-session, stop, run it immediately, re-read the diff, and adjust your behavior before continuing.
- `compose-agentsmd` intentionally regenerates `AGENTS.md`; any resulting `AGENTS.md` diff is expected and must not be treated as an unexpected external change.
- If `compose-agentsmd` is not available, install it via npm: `npm install -g compose-agentsmd`.
- To update shared/global rules, use `compose-agentsmd edit-rules` to locate the writable rules workspace, make changes only in that workspace, then run `compose-agentsmd apply-rules` (do not manually clone or edit the rules source repo outside this workflow).
- If you find an existing clone of the rules source repo elsewhere, do not assume it is the correct rules workspace; always treat `compose-agentsmd edit-rules` output as the source of truth.
- `compose-agentsmd apply-rules` pushes the rules workspace when `source` is GitHub (if the workspace is clean), then regenerates `AGENTS.md` with refreshed rules.
- Do not edit `AGENTS.md` directly; update the source rules and regenerate.
- `tools/tool-rules.md` is the shared rule source for all repositories that use compose-agentsmd.
- Before applying any rule updates, present the planned changes first with an ANSI-colored diff-style preview, ask for explicit approval, then make the edits.
- These tool rules live in tools/tool-rules.md in the compose-agentsmd repository; do not duplicate them in other rule modules.

Source: agent-rules-local/ghws-workspace.md

# GHWS workspace repository management

This module applies only when the repository path is under the
ghws workspace root. The agent MUST ignore this module for
standalone clones outside ghws.

## Definitions

- **GHWS workspace** — the directory tree rooted at the local
  `ghws` checkout. Each immediate child directory (except
  `agent-rules-local`) is a Git repository connected to GitHub.
- **User-controlled repository** — defined in `identity-and-scope`.

## Workspace topology

- Every folder in this workspace except `agent-rules-local` MUST
  be a Git repository connected to GitHub.
- Some repositories in this workspace are NOT owned by the user,
  but the user holds authoritative write access. The agent MAY
  treat such repositories as user-controlled for this workspace.

## Resolving target repositories

- If the target repository already exists under the current ghws
  workspace, the agent MUST edit it in place.
- If the target repository is not present under the current ghws
  workspace, the agent MUST clone it from GitHub with
  `--recursive` and then work in the cloned folder.
- The agent MUST NOT clone repositories that are not managed by
  the user into the ghws workspace.

## New repository creation

- When adding a new repository, the agent MUST create it under
  the ghws workspace first and then push it to GitHub.

## Account-wide scope

- For account-wide requests, the agent MUST treat all
  user-controlled repositories as in scope. Repository creation,
  splitting, and deletion are permitted within that scope per
  `identity-and-scope`.
