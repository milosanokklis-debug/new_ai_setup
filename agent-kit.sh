#!/usr/bin/env bash
# agent-kit.sh — build and use a personal Claude Code plugin marketplace.
#
#   ./agent-kit.sh init     [kit-dir]                 build the marketplace repo (default ./agent-kit)
#   ./agent-kit.sh sync     [kit-dir]                 re-pull vendored skills from upstream
#   ./agent-kit.sh register [kit-dir]                 add upstream + kit marketplaces to your user settings
#   ./agent-kit.sh project  <path> [design] [code] [--graph]
#                                                     wire a project to the kit (core is always on)
#   ./agent-kit.sh doctor                             show installed plugins and their token cost
#   ./agent-kit.sh free     [branch-name]             throwaway freellmapi session in a git worktree
#
# Env:
#   METHOD=agent-skills|superpowers   methodology layer for kit-core (default agent-skills)
#   KIT_REPO=you/agent-kit            GitHub repo you pushed the kit to (used in project settings)
#   KIT_NAME=agent-kit                marketplace name
#
# Requires: claude (Claude Code CLI), git, python3. Optional: uv (for graphify), node (for freellmapi).
# macOS/Linux/WSL. On Windows use WSL or Git Bash.

set -euo pipefail

KIT_NAME="${KIT_NAME:-agent-kit}"
METHOD="${METHOD:-agent-skills}"
KIT_VERSION="0.1.0"

# marketplace-name=github-repo. Adding a marketplace only adds a catalog; it loads nothing into context.
UPSTREAM_MARKETPLACES=(
  "addy-agent-skills=addyosmani/agent-skills"
  "superpowers-marketplace=obra/superpowers-marketplace"
  "mattpocock=mattpocock/skills"
  "hallmark=Nutlope/hallmark"
  "design-plugins=0xdesign/design-plugin"
)

# plugin|github-repo|path-in-repo  (all MIT; LICENSE is copied alongside each skill)
VENDORED=(
  "kit-core|vercel-labs/skills|skills/find-skills"
  "kit-design|shadcn-ui/ui|skills/shadcn"
  "kit-design|emilkowalski/skills|skills/emil-design-eng"
  "kit-code|DietrichGebert/ponytail|skills/ponytail-review"
)

case "$METHOD" in
  agent-skills) METHOD_DEP="agent-skills@addy-agent-skills" ;;
  superpowers)  METHOD_DEP="superpowers@superpowers-marketplace" ;;
  *) echo "METHOD must be agent-skills or superpowers" >&2; exit 1 ;;
esac

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' — $2"; }

check_prereqs() {
  need claude  "install Claude Code first"
  need git     "install git"
  need python3 "install Python 3"
}

# ---------------------------------------------------------------- vendoring
vendor_one() { # repo path dest-dir  -> prints upstream commit sha
  local repo="$1" path="$2" dest="$3" tmp
  tmp="$(mktemp -d)"
  git clone -q --depth 1 --filter=blob:none --sparse "https://github.com/$repo.git" "$tmp/r"
  git -C "$tmp/r" sparse-checkout set "$path" 2>/dev/null
  [ -f "$tmp/r/$path/SKILL.md" ] || { rm -rf "$tmp"; die "$repo/$path/SKILL.md not found (upstream moved it?)"; }
  rm -rf "$dest"; mkdir -p "$(dirname "$dest")"
  cp -R "$tmp/r/$path" "$dest"
  for f in LICENSE LICENSE.md LICENSE.txt; do
    [ -f "$tmp/r/$f" ] && { cp "$tmp/r/$f" "$dest/LICENSE"; break; }
  done
  git -C "$tmp/r" rev-parse --short=12 HEAD
  rm -rf "$tmp"
}

# Make a skill user-invoked only: its description leaves the context and Claude can't auto-trigger it.
make_user_only() {
  python3 - "$1" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
m = re.match(r'^---\n(.*?)\n---\n', s, re.S)
if m and 'disable-model-invocation' not in m.group(1):
    s = '---\n' + m.group(1) + '\ndisable-model-invocation: true\n---\n' + s[m.end():]
    open(p, 'w').write(s)
PY
}

vendor_all() {
  local kit="$1" plugin repo path name sha log="$1/VENDORED.md"
  printf '# Vendored skills\n\nCopied from upstream by agent-kit.sh on %s. Re-run `./agent-kit.sh sync` to update.\n\n| Skill | Plugin | Upstream | Commit |\n|---|---|---|---|\n' "$(date +%F)" > "$log"
  for row in "${VENDORED[@]}"; do
    IFS='|' read -r plugin repo path <<<"$row"
    name="$(basename "$path")"
    say "vendoring $name from $repo"
    sha="$(vendor_one "$repo" "$path" "$kit/plugins/$plugin/skills/$name")"
    printf '| %s | %s | [%s](https://github.com/%s/tree/%s/%s) | %s |\n' "$name" "$plugin" "$repo" "$repo" "$sha" "$path" "$sha" >> "$log"
  done
  # find-skills installs things from an open registry: keep it manual-only.
  make_user_only "$kit/plugins/kit-core/skills/find-skills/SKILL.md"
}

# ---------------------------------------------------------------- kit files
write_json() { python3 -c 'import json,sys; json.dump(json.loads(sys.argv[2]), open(sys.argv[1],"w"), indent=2); open(sys.argv[1],"a").write("\n")' "$1" "$2"; }

write_kit() {
  local kit="$1"
  mkdir -p "$kit/.claude-plugin" "$kit/plugins"/{kit-core,kit-design,kit-code}/{.claude-plugin,agents,skills}

  write_json "$kit/.claude-plugin/marketplace.json" "$(cat <<JSON
{
  "name": "$KIT_NAME",
  "owner": { "name": "$(git config user.name 2>/dev/null || echo me)" },
  "description": "Personal Claude Code kit: core + design + code packs",
  "metadata": { "description": "Personal Claude Code kit: core + design + code packs", "version": "$KIT_VERSION" },
  "allowCrossMarketplaceDependenciesOn": ["addy-agent-skills", "superpowers-marketplace", "mattpocock", "hallmark", "design-plugins"],
  "plugins": [
    { "name": "kit-core", "source": "./plugins/kit-core", "version": "$KIT_VERSION",
      "description": "Always-on base: methodology layer, Matt Pocock's planning skills, find-skills (manual).",
      "dependencies": ["$METHOD_DEP", "mattpocock-skills@mattpocock"] },
    { "name": "kit-design", "source": "./plugins/kit-design", "version": "$KIT_VERSION",
      "description": "UI pack: designer + design-auditor agents, shadcn, emil-design-eng, Hallmark, Design and Refine.",
      "dependencies": ["kit-core", "hallmark@hallmark", "design-and-refine@design-plugins"] },
    { "name": "kit-code", "source": "./plugins/kit-code", "version": "$KIT_VERSION",
      "description": "Code pack: coder, reviewer and simplicity-reviewer agents, ponytail-review.",
      "dependencies": ["kit-core"] }
  ]
}
JSON
)"

  local author; author="$(git config user.name 2>/dev/null || echo me)"
  for p in kit-core kit-design kit-code; do
    write_json "$kit/plugins/$p/.claude-plugin/plugin.json" \
      "{\"name\":\"$p\",\"version\":\"$KIT_VERSION\",\"description\":\"$p for $KIT_NAME\",\"license\":\"MIT\",\"author\":{\"name\":\"$author\"}}"
  done
  cat > "$kit/plugins/kit-core/README.md" <<MD
# kit-core
Always-on base of the $KIT_NAME marketplace. Installing it pulls in the methodology layer ($METHOD_DEP)
and Matt Pocock's skills (grill-me, wayfinder, handoff, tdd and more), and adds a manual-only copy of
Vercel's find-skills so new skills are only installed when you ask. Enable it in every project.
MD
  cat > "$kit/plugins/kit-design/README.md" <<MD
# kit-design
UI pack for the $KIT_NAME marketplace. Adds the designer agent (preloads shadcn, loads emil-design-eng
for motion and polish) and the read-only design-auditor agent (web-design-guidelines plus Hallmark audit).
Pulls in Hallmark and Design and Refine as dependencies. Enable it only in projects with a frontend.
MD
  cat > "$kit/plugins/kit-code/README.md" <<MD
# kit-code
Code pack for the $KIT_NAME marketplace. Adds the coder agent, a read-only correctness and security
reviewer, and a haiku-model simplicity-reviewer that runs ponytail-review over the diff. Only the
ponytail reviewer is included, not the always-on ponytail ruleset, so nothing is injected every turn.
MD

  # ---- kit-design agents
  cat > "$kit/plugins/kit-design/agents/designer.md" <<'MD'
---
name: designer
description: Builds and polishes UI in this project — new screens, components, layout, visual polish, motion. Use for any frontend visual work. Not for backend logic or data plumbing.
model: sonnet
tools: Read, Write, Edit, Glob, Grep, Bash
skills:
  - shadcn
---
You are the project's design engineer.

Order of authority when rules conflict: the project's existing design tokens and components > shadcn conventions > everything else.

- Unsure of direction, or the user wants options: tell the main session to run /design-and-refine:start instead of guessing.
- Motion, easing, transitions, micro-interactions or "make it feel better": load the emil-design-eng skill first.
- Marketing or landing pages: you may use the hallmark skill for structure and theme; for app UI inside an existing design system, do not.
- Before reporting done, list the files you changed and anything you could not verify visually.
MD

  cat > "$kit/plugins/kit-design/agents/design-auditor.md" <<'MD'
---
name: design-auditor
description: Read-only UI audit — accessibility, interaction states, Web Interface Guidelines, AI-slop patterns. Use after UI changes and before merging frontend work. Never edits files.
model: sonnet
tools: Read, Glob, Grep, WebFetch
---
You audit; you never edit.

1. Run the web-design-guidelines skill over the changed UI files (it fetches the current guidelines).
2. Run the hallmark skill in audit mode for generic-AI-design patterns.
3. Return one merged punch list, highest impact first, each item as `file:line — problem — fix`. Drop duplicates between the two sources. No praise, no summary of what is fine.
MD

  # ---- kit-code agents
  cat > "$kit/plugins/kit-code/agents/coder.md" <<'MD'
---
name: coder
description: Implements features and fixes in this project's code — writing code, tests, refactors. Use for scoped implementation tasks with a clear goal. Not for UI visual design.
model: sonnet
tools: Read, Write, Edit, Glob, Grep, Bash
---
You implement one scoped task at a time.

- Follow the methodology skills installed with kit-core (spec before code, tests first where practical, verify before claiming done).
- Prefer the platform, the standard library and code that already exists in the repo over new code or new dependencies.
- If graphify-out/GRAPH_REPORT.md exists, read it before searching the codebase.
- Finish with: what changed, how you verified it (commands run and their result), and anything left undone.
MD

  cat > "$kit/plugins/kit-code/agents/reviewer.md" <<'MD'
---
name: reviewer
description: Correctness and security review of the current diff — bugs, edge cases, error handling, security, missing tests. Use before merging any code change. Read-only.
tools: Read, Glob, Grep, Bash
---
Review `git diff` (or the diff against the base branch if asked) for correctness and security only. Ignore style.

If a code-review skill is available (agent-skills' code-review-and-quality, or Matt Pocock's code-review), follow it.

Return findings as `file:line — severity (blocker/major/minor) — problem — suggested fix`, blockers first. If there are none, say so in one line. Do not edit files.
MD

  cat > "$kit/plugins/kit-code/agents/simplicity-reviewer.md" <<'MD'
---
name: simplicity-reviewer
description: Over-engineering review of the current diff — dead code, needless abstraction, dependencies doing what the platform already does. Use alongside the reviewer agent before merging. Read-only.
model: haiku
tools: Read, Glob, Grep, Bash
skills:
  - ponytail-review
---
Apply the ponytail-review skill to `git diff`. Return only its delete/simplify list. Do not edit files. Correctness and security are the reviewer agent's job, not yours.
MD

  cat > "$kit/README.md" <<MD
# $KIT_NAME

Personal Claude Code plugin marketplace, generated by agent-kit.sh.

| Plugin | What it adds | Depends on |
|---|---|---|
| kit-core | find-skills (manual-only) | $METHOD_DEP, mattpocock-skills@mattpocock |
| kit-design | designer, design-auditor agents; shadcn, emil-design-eng skills | kit-core, hallmark@hallmark, design-and-refine@design-plugins |
| kit-code | coder, reviewer, simplicity-reviewer agents; ponytail-review skill | kit-core |

Install into a project: \`./agent-kit.sh project <path> design code\`.
Vendored skill sources and commits: VENDORED.md.
MD
}

# ---------------------------------------------------------------- commands
cmd_init() {
  local kit="${1:-./agent-kit}"
  check_prereqs
  [ -e "$kit/.claude-plugin/marketplace.json" ] && die "$kit already exists — use: $0 sync $kit"
  mkdir -p "$kit"; kit="$(cd "$kit" && pwd)"
  say "writing kit to $kit (METHOD=$METHOD)"
  write_kit "$kit"
  vendor_all "$kit"
  say "validating"
  claude plugin validate "$kit"
  for p in kit-core kit-design kit-code; do claude plugin validate "$kit/plugins/$p"; done
  if [ ! -d "$kit/.git" ]; then
    git -C "$kit" init -q
    git -C "$kit" add -A
    git -C "$kit" commit -qm "agent-kit $KIT_VERSION" || true
  fi
  say "done. Next:"
  echo "   1. Create an empty GitHub repo (private is fine), then:"
  echo "      git -C $kit remote add origin git@github.com:YOU/$KIT_NAME.git && git -C $kit push -u origin HEAD"
  echo "   2. $0 register $kit"
  echo "   3. KIT_REPO=YOU/$KIT_NAME $0 project /path/to/project design code"
}

cmd_sync() {
  local kit="${1:-./agent-kit}"
  check_prereqs
  [ -f "$kit/.claude-plugin/marketplace.json" ] || die "no kit at $kit"
  kit="$(cd "$kit" && pwd)"
  vendor_all "$kit"
  claude plugin validate "$kit"
  say "review with: git -C $kit diff --stat   then commit, push, and run: claude plugin marketplace update $KIT_NAME"
}

cmd_register() {
  local src="${1:-./agent-kit}" row name repo
  check_prereqs
  for row in "${UPSTREAM_MARKETPLACES[@]}"; do
    name="${row%%=*}"; repo="${row#*=}"
    if claude plugin marketplace list 2>/dev/null | grep -q "$name"; then
      say "marketplace $name already added"
    else
      say "adding marketplace $name ($repo)"
      # HTTPS URL avoids the SSH clone failures some people hit with owner/repo
      claude plugin marketplace add "https://github.com/$repo.git"
    fi
  done
  [ -d "$src" ] && src="$(cd "$src" && pwd)"
  if claude plugin marketplace list 2>/dev/null | grep -q "$KIT_NAME"; then
    say "marketplace $KIT_NAME already added (update with: claude plugin marketplace update $KIT_NAME)"
  else
    say "adding your kit marketplace from $src"
    claude plugin marketplace add "$src"
  fi
  say "nothing is installed yet — run: $0 project <path> [design] [code]"
}

cmd_project() {
  [ $# -ge 1 ] || die "usage: $0 project <path> [design] [code] [--graph]"
  local proj="$1"; shift
  local packs=("kit-core") graph=0 a
  for a in "$@"; do
    case "$a" in
      design) packs+=("kit-design") ;;
      code)   packs+=("kit-code") ;;
      --graph) graph=1 ;;
      *) die "unknown option: $a" ;;
    esac
  done
  check_prereqs
  mkdir -p "$proj/.claude"; proj="$(cd "$proj" && pwd)"
  claude plugin marketplace list 2>/dev/null | grep -q "$KIT_NAME" || die "kit marketplace not registered — run: $0 register"

  # 1. committed settings so anyone who clones the project knows where the plugins come from
  local markets="" row
  for row in "${UPSTREAM_MARKETPLACES[@]}"; do markets+="${row%%=*}=${row#*=};"; done
  [ -n "${KIT_REPO:-}" ] && markets+="$KIT_NAME=$KIT_REPO;" || warn "KIT_REPO not set — project settings won't tell other machines where $KIT_NAME lives"
  python3 - "$proj/.claude/settings.json" "$markets" <<'PY'
import json, os, sys
path, markets = sys.argv[1], sys.argv[2]
s = json.load(open(path)) if os.path.exists(path) else {}
ekm = s.setdefault("extraKnownMarketplaces", {})
for pair in filter(None, markets.split(";")):
    name, repo = pair.split("=", 1)
    ekm[name] = {"source": {"source": "github", "repo": repo}}
json.dump(s, open(path, "w"), indent=2); open(path, "a").write("\n")
PY

  # 2. install the packs at project scope (dependencies come along automatically)
  for p in "${packs[@]}"; do
    say "installing $p@$KIT_NAME (project scope)"
    (cd "$proj" && claude plugin install "$p@$KIT_NAME" --scope project)
  done

  # 3. web-design-guidelines has no license file upstream, so it is fetched into the project rather than vendored
  if [[ " ${packs[*]} " == *" kit-design "* ]]; then
    say "fetching web-design-guidelines into $proj/.claude/skills"
    vendor_one vercel-labs/agent-skills skills/web-design-guidelines "$proj/.claude/skills/web-design-guidelines" >/dev/null
  fi

  # 4. short routing note — CLAUDE.md is loaded every turn, so keep it tiny
  if ! grep -q "agent-kit:start" "$proj/CLAUDE.md" 2>/dev/null; then
    {
      printf '\n<!-- agent-kit:start -->\n## Working with the agent kit\n'
      printf -- '- Start new features with /grill-me (or /wayfinder for big ones); end long sessions with /handoff.\n'
      [[ " ${packs[*]} " == *" kit-design "* ]] && \
        printf -- '- UI work → designer agent. After UI changes → design-auditor agent. Unsure of direction → /design-and-refine:start.\n'
      [[ " ${packs[*]} " == *" kit-code "* ]] && \
        printf -- '- Code work → coder agent. Before any merge → reviewer and simplicity-reviewer agents, in parallel.\n'
      printf -- '- Never install skills on your own; suggest them and wait (find-skills is manual-only).\n'
      printf '<!-- agent-kit:end -->\n'
    } >> "$proj/CLAUDE.md"
  fi

  # 5. optional codebase graph (only worth it on large repos)
  if [ "$graph" = 1 ]; then
    if ! command -v graphify >/dev/null 2>&1; then
      if command -v uv >/dev/null 2>&1; then
        say "installing graphify CLI (PyPI package: graphifyy)"
        uv tool install graphifyy || warn "graphify install failed — try: pipx install graphifyy"
      else
        warn "uv not found — install it (https://docs.astral.sh/uv/) or run: pipx install graphifyy"
      fi
    fi
    if command -v graphify >/dev/null 2>&1; then
      (cd "$proj" && graphify install --project) || warn "graphify install --project failed"
      grep -qx 'graphify-out/' "$proj/.gitignore" 2>/dev/null || echo 'graphify-out/' >> "$proj/.gitignore"
      say "graphify ready — inside Claude Code run: /graphify ."
    else
      warn "skipped graphify; re-run this command with --graph once the CLI is installed"
    fi
  fi

  say "done. Commit $proj/.claude/settings.json, CLAUDE.md and .claude/skills/. Then open Claude Code there and run /context."
}

cmd_doctor() {
  check_prereqs
  claude plugin list
  for p in kit-core kit-design kit-code; do
    echo; say "$p"; claude plugin details "$p@$KIT_NAME" 2>/dev/null || echo "   not installed here"
  done
}

cmd_free() {
  local branch="${1:-free/$(date +%Y%m%d-%H%M)}" root wt
  need git "install git"; need npx "install Node.js 20+"
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run this inside a git repo"
  wt="$root/../$(basename "$root")-${branch//\//-}"
  git -C "$root" worktree add -q -b "$branch" "$wt"
  say "worktree $wt on branch $branch — free-tier models only; review before merging anything back"
  cd "$wt" && exec npx freellmapi launch
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    init) cmd_init "$@" ;;
    sync) cmd_sync "$@" ;;
    register) cmd_register "$@" ;;
    project) cmd_project "$@" ;;
    doctor) cmd_doctor ;;
    free) cmd_free "$@" ;;
    *) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0" ;;
  esac
}
main "$@"
