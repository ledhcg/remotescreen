# Git

- Conventional Commits: `type(scope): imperative summary` (feat, fix, docs, test, refactor, perf, chore, ci, security).
  The body explains *why*. One logical change per commit.
- Commit only when asked. Never push, force-push, amend published commits, rewrite history, or change repository visibility
  unless explicitly asked.
- Before committing: `swift build && swift test`, and `gitleaks git --staged --redact`.
- Branch from `main`; pull requests need CI green and a `CHANGELOG.md` line for user-visible changes.
