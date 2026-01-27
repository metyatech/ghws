# GHWS workspace repository management

- These rules apply only when working inside the `ghws` workspace repository (the exact path may vary).
- All folders in this workspace (except `agent-rules-local`) are Git repositories connected to GitHub.
- Some repositories are not owned by the user, but the user can commit and push to them.
- If the target repository already exists under the current `ghws` workspace, edit it in place.
- If the target repository is not present under the current `ghws` workspace, clone it from GitHub with `--recursive` and then work in the cloned folder.
- When adding a new repository, create it under the `ghws` workspace first and then push it to GitHub.
- Never clone repositories that are not managed by the user into the `ghws` workspace.
