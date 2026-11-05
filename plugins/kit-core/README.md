# kit-core
Always-on base of the agent-kit marketplace. Installing it pulls in the methodology layer (agent-skills@addy-agent-skills),
adds a manual-only copy of Vercel's find-skills so new skills are only installed when you ask, and the
orchestrator guard: a PreToolUse hook that stops an agent of type `orchestrator` (main session or subagent) from
changing files itself (Edit/Write, and Bash that writes files), so the work goes to the coder and designer agents.
It limits `lead` to the handoff file and `supervisor` to `docs/handoff/runs/<name>.md`. Other subagents and a
`claude --agent solo` session are untouched. Planning skills come from your zsl plugin, or from
Matt Pocock's skills, which `project` installs when zsl isn't there. Enable it in every project.

MCP servers (`.mcp.json`, granted to agents per `tools:` entry, never to the orchestrator): playwright and
chrome-devtools (headless browser checks), context7 (current library docs). Needs Node.
