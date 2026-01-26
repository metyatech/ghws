# GHWS workspace repository management

- These rules apply only when working inside the `ghws` workspace repository (the exact path may vary).
- All repositories in this workspace are the user's GitHub repositories.
- If the target repository already exists under the current `ghws` workspace, edit it in place.
- If the target repository is not present under the current `ghws` workspace, clone it from GitHub with `--recursive` and then work in the cloned folder.
- When adding a new repository, create it under the `ghws` workspace first and then push it to GitHub.
