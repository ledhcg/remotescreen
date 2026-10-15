# Agent instructions

The authoritative guide for AI coding agents is [CLAUDE.md](CLAUDE.md). Read it before making changes; it points to the rules in
`.claude/rules/` and the procedures in `.claude/skills/`. The short version:

- Build/test: `swift build && swift test`; iOS app: `cd App && xcodegen generate`, then `xcodebuild … build` for the simulator.
- Treat every length/count from the server as hostile and bound it before allocating.
- Never downgrade authentication silently. Never log or commit passwords, captures, hostnames or team IDs.
- Never test against a real Mac unless asked; use `Tools/mock-rfb-server` and the simulator.
- No third-party dependencies. Keep each file in the language it already uses (code/docs Vietnamese, project files English).
- Do not rewrite history, force-push, publish or release unless asked. Commits follow Conventional Commits and only when asked.
