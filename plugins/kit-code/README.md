# kit-code
Code pack for the agent-kit marketplace. Adds the coder agent, a read-only correctness and security
reviewer, and a haiku-model simplicity-reviewer that runs ponytail-review over the diff. Two more haiku agents
keep routine work off the bigger models: runner (checks, tests, git status/diff, log digging; read-only) and
coder-lite (clear-step work in up to about three files: renames, doc/copy/config tweaks, tests that copy a
pattern, bug fixes with a known cause; it bounces design decisions and multi-module changes to the coder). Only the
ponytail reviewer is included, not the always-on ponytail ruleset, so nothing is injected every turn.
The reviewer also gets the Semgrep MCP server (`semgrep mcp`, from the semgrep binary that `setup` installs).
