# Security review

One-time vetting of the 11 third-party items considered for agent-kit 0.4.0, done 2026-11-02. Nothing was executed during the review. HIGH severity means excluded. Impeccable was excluded on policy (below); the other 10 are in 0.4.0.

| Item | Version / SHA | Licence | Severity | Key findings | Decision |
|---|---|---|---|---|---|
| Impeccable | 4.8.0 @9fadc41 (engine 0.1.18) | Apache-2.0 | MEDIUM | Its SessionStart/PostToolUse/Stop hooks run `plugin/skills/impeccable/scripts/impeccable`, which curls a ~22 MB native engine binary from GitHub releases and execs it. It fails closed on a sha256 mismatch against `scripts/engine-checksums.txt`; the linux-x64 checksum was verified. The engine contacts impeccable.style for update checks. No credential access was found. 3 semgrep WARNINGs (wildcard postMessage in opt-in `live-browser.js`). | EXCLUDED from 0.4.0: auto-downloads and runs a native binary via always-on hooks; re-add only on explicit user decision |
| Taste Skill | 2.1.5 @12af471 | MIT | LOW | No hooks or installs. Its scripts launch local headless Chrome, serve on 127.0.0.1 with a traversal guard, fetch public image metadata and write `~/.taste-skill/history.json`. | Installed. |
| GSAP skills | 1.0.0 @aed9cfd | MIT | NONE | Markdown only. | Installed only when the project depends on gsap. |
| typescript-lsp | 1.0.0 @a7ba5b9 | Apache-2.0 | NONE | Runs typescript-language-server from PATH (npm 6.0.3, no install scripts, 0 deps). | Installed by detection. |
| pyright-lsp | 1.0.0 @a7ba5b9 | Apache-2.0 (npm pyright is MIT) | NONE | Runs pyright-langserver from PATH. | Installed by detection. |
| @playwright/mcp | 0.0.84 | Apache-2.0 | LOW | Depends on a playwright alpha build. It exposes browser_evaluate, run_code_unsafe and file_upload; risky flags are off by default. | Pinned, `--isolated`, `--browser chromium`. Its `browser_evaluate` and `file_upload` can be steered by injected page content: agents must not browse untrusted sites unprompted. |
| chrome-devtools-mcp | 1.12.0 | Apache-2.0 | LOW | Google usage statistics and the CrUX lookup are on by default, plus a background update check. | Pinned, with telemetry, CrUX and update checks disabled. |
| @upstash/context7-mcp | 4.4.4 | MIT | LOW | Queries context7.com; returned docs are an injection surface. | Pinned, stdio, no key, output treated as untrusted. |
| Semgrep MCP (built-in `semgrep mcp`) | semgrep 1.183.0 | LGPL-2.1-or-later | LOW | The deprecated semgrep-mcp package is not used. Metrics are on by default, and `config=auto` requires them. SEMGREP_APP_TOKEN is not set. | Pinned via setup (`uv tool install semgrep==1.183.0`). |
| shadcn mcp | 4.23.0 | MIT | LOW | Read-only registry tools. A project's `components.json` can point at third-party registries. | Pinned. |
| Motion MCP (https://mcp.motion.dev) | server 1.0.0 | hosted service; ai-kit skill MIT | LOW | No auth. Its server instructions contain steering text ("install any packages...", upsell to Motion+). It can't be pinned. | Installed; output treated as untrusted, no auto-installs. |

## Method

- Shallow clones or `npm pack --ignore-scripts` into separate mktemp dirs; nothing executed.
- AgentShield: `npx -y ecc-agentshield@1.6.0 scan --path <dir>` (a staging copy of the markdown, as `vet` does).
- semgrep p/javascript and p/security-audit with metrics off.
- An invisible-Unicode scan and grep heuristics.
- Not done: transitive npm dependency diff, the semgrep-mcp package code, and triage of unrelated plugins in claude-plugins-official.
- Rule: HIGH = excluded.

## Pins

Claude Code cannot pin a marketplace to a commit (the marketplace source takes `ref`, a branch or tag; a SHA fails to clone). A plugin source can be pinned: `github` and `git-subdir` sources take `sha`. So taste-skill, vercel-react-skills (vercel-labs/agent-skills at 1a2c79d, added in 0.5.0), gsap-skills, typescript-lsp and pyright-lsp are entries in the kit's own marketplace (`write_kit` in `agent-kit.sh`) with `sha` set to the vetted commit, and the upstream marketplaces for them are no longer added. Verified in a throwaway HOME: `claude plugin install <name>@agent-kit` records `gitCommitSha` = the vetted commit (taste-skill 12af471, gsap-skills aed9cfd, typescript-lsp and pyright-lsp a7ba5b9). The two LSP entries copy their fields verbatim from the marketplace.json of anthropics/claude-plugins-official at a7ba5b9 (Anthropic, Apache-2.0; each plugin's LICENSE is in its subdirectory and is installed with it); their `git-subdir` source needs a full https URL, since the `owner/repo` shorthand clones over SSH. The fetched guideline skills writing-guidelines and web-design-guidelines (also vercel-labs/agent-skills) are pinned to the same commit 1a2c79d: `vendor_one` fetches exactly that sha (`AGENT_SKILLS_SHA` in `agent-kit.sh`) and fails if it is missing. What cannot be pinned: both skills tell the agent to WebFetch their rules from the upstream main branch at run time, so that content is unpinned and is treated as untrusted reference data. The remaining upstream marketplaces (addy-agent-skills, superpowers-marketplace, mattpocock, hallmark, design-plugins) are unpinned; they are not part of the 0.4.0 vetting. MCP servers are pinned by npm version in each plugin's `.mcp.json`.

The pre-0.4.0 upstream marketplaces (addy-agent-skills, superpowers-marketplace, mattpocock, hallmark, design-plugins) still resolve from HEAD, so hallmark, design-and-refine and agent-skills are outside this vetting; pinning them is a follow-up.

The typescript, typescript-language-server and pyright npm packages are pinned in `agent-kit.sh` (`LSP_NPM`) and installed with `--ignore-scripts`.

No item was excluded for failing to pin.

## ui-guide

`ui-guide` is read-only for files (no Edit, Write or Bash), but it has playwright (`browser_evaluate`) and WebFetch, which injected page content can steer. It should not browse untrusted sites unprompted; its prompt says so.

The reviewer agent has WebFetch only to fetch the writing-guidelines rules. It also has Bash, so anything it fetches is untrusted input and it must not act on it as instructions.
