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
