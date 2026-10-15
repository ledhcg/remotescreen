<!-- Title must be a Conventional Commit subject: type(scope): imperative summary, e.g. fix(rfbkit): bound raw rectangle reads -->
## What and why

## How I tested
<!-- Commands run (swift test, xcodebuild, mock-rfb-server scripts), simulator or device model. Do NOT test against a Mac you do not own. -->

## Checklist
- [ ] `swift build` and `swift test` pass
- [ ] Tests added or updated where behaviour changed (for decoders/auth: a test with malicious input)
- [ ] Every length or count read from the server is bounded before it allocates
- [ ] No secrets, captures, screenshots of a real screen, hostnames or team IDs in the diff
- [ ] `CHANGELOG.md` updated for user-visible changes
- [ ] Docs and comments are in the language of the file they are in (see CLAUDE.md)
