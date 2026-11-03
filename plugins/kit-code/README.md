# kit-code
Code pack for the agent-kit marketplace. Adds the coder agent, a read-only correctness and security
reviewer, and a haiku-model simplicity-reviewer that runs ponytail-review over the diff. Only the
ponytail reviewer is included, not the always-on ponytail ruleset, so nothing is injected every turn.
The reviewer also gets the Semgrep MCP server (`semgrep mcp`, from the semgrep binary that `setup` installs).
