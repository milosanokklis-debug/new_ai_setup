# kit-core
Always-on base of the agent-kit marketplace. Installing it pulls in the methodology layer (agent-skills@addy-agent-skills),
adds a manual-only copy of Vercel's find-skills so new skills are only installed when you ask, and the
orchestrator guard: a PreToolUse hook that stops the orchestrator main session from changing files itself
(Edit/Write, and Bash that writes files), so the work goes to the coder and designer agents. It never
touches subagents or a `claude --agent solo` session. Planning skills come from your zsl plugin, or from
Matt Pocock's skills, which `project` installs when zsl isn't there. Enable it in every project.
