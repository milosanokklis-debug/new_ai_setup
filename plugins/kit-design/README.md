# kit-design
UI pack for the agent-kit marketplace. Adds the designer agent (preloads shadcn; loads emil-design-eng
for motion and polish) and the read-only, haiku-model design-auditor agent (web-design-guidelines plus Hallmark audit).
Pulls in Hallmark, Design and Refine and Taste as dependencies (Taste is listed in the agent-kit marketplace, pinned by `sha` to the vetted commit). Adds the ui-references skill (animation and design sites, plus the rules for borrowing from them)
and the shadcn and Motion MCP servers. `project` also writes a read-only `ui-guide` agent (claude --agent ui-guide)
for questions about these skills. Enable it only in projects with a frontend.
