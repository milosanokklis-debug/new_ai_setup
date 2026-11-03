# Vendored skills

Copied from upstream by agent-kit.sh on 2026-10-23. Re-run `./agent-kit.sh sync` to update.

| Skill | Plugin | Upstream | Commit |
|---|---|---|---|
| find-skills | kit-core | [vercel-labs/skills](https://github.com/vercel-labs/skills/tree/a80e4c9d12d6/skills/find-skills) | a80e4c9d12d6 |
| shadcn | kit-design | [shadcn-ui/ui](https://github.com/shadcn-ui/ui/tree/e55b60b1014c/skills/shadcn) | e55b60b1014c |
| emil-design-eng | kit-design | [emilkowalski/skills](https://github.com/emilkowalski/skills/tree/2d228630ba14/skills/emil-design-eng) | 2d228630ba14 |
| ponytail-review | kit-code | [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail/tree/09c434ab73ca/skills/ponytail-review) | 09c434ab73ca |

Pinned or fetched instead of vendored (not synced by `sync`):

- **vercel-react-skills** (react-best-practices, composition-patterns, react-view-transitions): listed in this kit's `marketplace.json`, pinned by `sha` to [vercel-labs/agent-skills@1a2c79d](https://github.com/vercel-labs/agent-skills/tree/1a2c79d4e6c4a2283dc2c614b6538cbe1ed5ca62), MIT. Same pattern as taste-skill and gsap-skills.
- **writing-guidelines** and **web-design-guidelines**: fetched by `agent-kit.sh project` from vercel-labs/agent-skills into the project's `.claude/skills` and gitignored, because upstream ships no licence file. writing-guidelines is fetched for every project; web-design-guidelines only with the design pack. Both are fetched at the pinned commit 1a2c79d (`AGENT_SKILLS_SHA` in `agent-kit.sh`), but each skill still WebFetches its rules from the upstream main branch at run time, and that part cannot be pinned. A failed fetch only warns. The reviewer (read-only, WebFetch) uses writing-guidelines for prose findings; the coder does not, since it has no WebFetch.
