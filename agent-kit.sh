#!/usr/bin/env bash
# agent-kit.sh — build and use a personal Claude Code plugin marketplace.
#
#   ./agent-kit.sh init     [kit-dir]                 build the marketplace repo (default ./agent-kit)
#   ./agent-kit.sh sync     [kit-dir]                 re-pull vendored skills from upstream
#   ./agent-kit.sh register [kit-dir]                 add upstream + kit marketplaces to your user settings
#   ./agent-kit.sh project  <path> [design] [code] [--graph] [--no-memory]
#                                                     wire a project to the kit (core is always on)
#   ./agent-kit.sh repo     <path> [--public] [--no-github] [--name NAME]
#                                                     git + GitHub repo with green-light gates (gitleaks,
#                                                     verify, independent reviewer) and branch protection
#   ./agent-kit.sh new      <path> [design] [code] [--graph] [--no-memory] [--public] [--no-github]
#                                                     start a project: repo + gates + kit, in one step
#   ./agent-kit.sh doctor   [--scan]                  installed plugins, skills per plugin and their token
#                                                     cost; --scan adds an AgentShield security scan
#
# Env:
#   METHOD=agent-skills|superpowers   methodology layer for kit-core (default agent-skills)
#   KIT_REPO=you/agent-kit            GitHub repo you pushed the kit to (used in project settings)
#   KIT_NAME=agent-kit                marketplace name
#   REVIEW_MODEL=sonnet|opus|haiku    model for the pre-push reviewer (default sonnet; REVIEWER=off disables)
#   BM_HOME=~/basic-memory            where each project's Basic Memory notes folder is created
#
# Requires: claude (Claude Code CLI), git, python3, uv (Basic Memory; installed via Homebrew if missing).
# Optional: node (AgentShield),
# gh + gitleaks (repo/new). Everything AI runs on your Claude Pro/Max login.
# macOS/Linux/WSL. On Windows use WSL or Git Bash.

set -euo pipefail

KIT_NAME="${KIT_NAME:-agent-kit}"
METHOD="${METHOD:-agent-skills}"
KIT_VERSION="0.2.0"
GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.30.1}"
BM_HOME="${BM_HOME:-$HOME/basic-memory}"

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
  - emil-design-eng
---
You are the project's design engineer.

Order of authority when rules conflict: the project's existing design tokens and components > shadcn conventions > everything else.

- Unsure of direction, or the user wants options: tell the main session to run /design-and-refine:start instead of guessing.
- Motion, easing, transitions, micro-interactions or "make it feel better": follow the preloaded emil-design-eng skill.
- Marketing or landing pages: you may use the hallmark skill for structure and theme; for app UI inside an existing design system, do not.
- Before reporting done, list the files you changed and anything you could not verify visually.
MD

  cat > "$kit/plugins/kit-design/agents/design-auditor.md" <<'MD'
---
name: design-auditor
description: Read-only UI audit — accessibility, interaction states, Web Interface Guidelines, AI-slop patterns. Use after UI changes and before merging frontend work. Never edits files.
model: sonnet
tools: Read, Glob, Grep, WebFetch
skills:
  - web-design-guidelines
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
model: sonnet
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

  [ -f "$kit/README.md" ] || cat > "$kit/README.md" <<MD
# $KIT_NAME

Personal Claude Code plugin marketplace, generated by agent-kit.sh.

| Plugin | What it adds | Depends on |
|---|---|---|
| kit-core | find-skills (manual-only) | $METHOD_DEP, mattpocock-skills@mattpocock |
| kit-design | designer, design-auditor agents; shadcn, emil-design-eng skills | kit-core, hallmark@hallmark, design-and-refine@design-plugins |
| kit-code | coder, reviewer, simplicity-reviewer agents; ponytail-review skill | kit-core |

Start a new project (git, GitHub repo, gates, kit, Basic Memory): \`./agent-kit.sh new <path> design code\`.
Wire an existing project to the kit only: \`./agent-kit.sh project <path> design code\`.

## Green light before every push

\`repo\` and \`new\` add these to the project (all committed, so every clone gets them):

| Gate | Runs | Blocks when |
|---|---|---|
| gitleaks | every commit (staged files) and every push (new commits) | a secret is found |
| verify | every push, and in CI | \`scripts/verify.sh\` fails |
| independent reviewer | every push | it returns \`VERDICT: BLOCK\` or no verdict |
| GitHub branch protection | pull requests into main | the \`gitleaks\` or \`verify\` CI check isn't green |

The reviewer has no buy-in: a fresh Claude process with no session history, the diff only (no commit
messages), and read-only. It runs on your Pro login and skips docs-only pushes to save usage.
Model: \`REVIEW_MODEL=sonnet|opus|haiku\`. Skip once: \`SKIP_REVIEW=1 git push\` / \`SKIP_VERIFY=1 git push\`.

Check what the kit costs per turn: \`./agent-kit.sh doctor\` (add \`--scan\` for an AgentShield scan).
Vendored skill sources and commits: VENDORED.md.
MD
}

# ---------------------------------------------------------------- repo gates
# Files written into a project by `repo`. Hooks live in .githooks/ (committed) so every clone gets them.

write_gates() {
  local proj="$1"
  mkdir -p "$proj/.githooks" "$proj/scripts" "$proj/.github/workflows"

  cat > "$proj/.githooks/pre-commit" <<'SH'
#!/usr/bin/env bash
# agent-kit: block commits that contain secrets. Bypass once (not recommended): git commit --no-verify
set -euo pipefail
command -v gitleaks >/dev/null 2>&1 || {
  echo "pre-commit: gitleaks is not installed, so secrets can't be checked. Install it: brew install gitleaks (or see github.com/gitleaks/gitleaks/releases)" >&2
  exit 1
}
gitleaks git --staged --no-banner --redact . || {
  echo "pre-commit: gitleaks found a secret in the staged changes. Remove it (and rotate it if it was real), then commit again." >&2
  exit 1
}
SH

  cat > "$proj/.githooks/pre-push" <<'SH'
#!/usr/bin/env bash
# agent-kit green-light gate, run on every push:
#   1. gitleaks over the commits being pushed
#   2. scripts/verify.sh                (skip once: SKIP_VERIFY=1 git push)
#   3. scripts/independent-review.sh   (skip once: SKIP_REVIEW=1 git push)
# Bypass everything once (not recommended): git push --no-verify
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
empty="$(git hash-object -t tree /dev/null)"

mapfile -t refs   # read all ref lines first; the steps below must not eat stdin

for line in "${refs[@]}"; do
  read -r _lref lsha _rref rsha <<<"$line"
  [[ "$lsha" =~ ^0+$ ]] && continue                      # deleting a branch
  if [[ "$rsha" =~ ^0+$ ]]; then                          # new branch on the remote
    oldest="$(git rev-list --reverse "$lsha" --not --remotes | head -n1)"
    [ -z "$oldest" ] && continue                          # nothing new to push
    base="$(git rev-parse -q --verify "$oldest^" || echo "$empty")"
  else
    base="$rsha"
  fi
  if [ "$base" = "$empty" ]; then range="$lsha"; else range="$base..$lsha"; fi

  echo "[1/3] secrets: gitleaks"
  command -v gitleaks >/dev/null 2>&1 || { echo "pre-push: gitleaks is not installed (brew install gitleaks)." >&2; exit 1; }
  gitleaks git --no-banner --redact --log-opts="$range" . </dev/null || {
    echo "pre-push: gitleaks found a secret in the commits you're pushing. Remove it from history and rotate it." >&2
    exit 1
  }

  if [ "${SKIP_VERIFY:-}" = 1 ]; then echo "[2/3] verify: skipped"; else
    echo "[2/3] verify: scripts/verify.sh"
    bash scripts/verify.sh </dev/null || { echo "pre-push: verify failed — no green light, push stopped." >&2; exit 1; }
  fi

  if [ "${SKIP_REVIEW:-}" = 1 ]; then echo "[3/3] review: skipped"; else
    echo "[3/3] review: independent reviewer"
    bash scripts/independent-review.sh "$base" "$lsha" </dev/null || exit 1
  fi
done
SH

  [ -f "$proj/scripts/verify.sh" ] || cat > "$proj/scripts/verify.sh" <<'SH'
#!/usr/bin/env bash
# Green light = this script exits 0. The pre-push hook and CI both run it.
# It guesses your stack; replace the guesses with your real lint/typecheck/test commands as the project grows.
# Set VERIFY_REQUIRE_TESTS=1 to fail when no checks are found.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
ran=0

if [ -f package.json ]; then
  if [ -n "${CI:-}" ] && [ -f package-lock.json ]; then npm ci --silent
  elif [ ! -d node_modules ]; then npm install --silent; fi
  for s in lint typecheck test; do
    if node -e "process.exit(require('./package.json').scripts?.['$s'] ? 0 : 1)"; then
      npm run -s "$s"; ran=1
    fi
  done
fi

if [ -f pyproject.toml ] || [ -f requirements.txt ]; then
  if [ -n "${CI:-}" ]; then
    [ -f requirements.txt ] && pip install -q -r requirements.txt
    pip install -q pytest
  fi
  if command -v pytest >/dev/null 2>&1 && { [ -d tests ] || [ -d test ] || compgen -G "test_*.py" >/dev/null; }; then
    pytest -q; ran=1
  fi
fi

[ -f Cargo.toml ] && { cargo test --quiet; ran=1; }
[ -f go.mod ] && { go test ./...; ran=1; }

if [ "$ran" = 0 ]; then
  echo "verify: no checks found — add your test command to scripts/verify.sh"
  [ "${VERIFY_REQUIRE_TESTS:-}" = 1 ] && exit 1
fi
exit 0
SH

  cat > "$proj/scripts/independent-review.sh" <<'SH'
#!/usr/bin/env bash
# Independent pre-push reviewer with no buy-in:
#   - runs in a fresh process with no session history, so it never saw the plan or the author's reasoning
#   - gets the diff only, never the commit messages (the author's framing)
#   - read-only: it can open files for context but cannot change them
#   - runs on your Claude Pro/Max login, never API billing
# Model: REVIEW_MODEL=sonnet (default) | opus | haiku. Turn off: REVIEWER=off (or: git config kit.reviewer off).
# Docs-only pushes (*.md, *.txt, docs/) skip the review to save usage; gitleaks and verify still run.
# Usage: independent-review.sh <base> <head>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
base="$(git rev-parse "$1")"; head="$(git rev-parse "$2")"   # accept names like HEAD~1 when run by hand
cache="$(git rev-parse --git-dir)/kit-review"; mkdir -p "$cache"
[ -f "$cache/$head.pass" ] && { echo "review: already passed for ${head:0:12}"; exit 0; }

engine="${REVIEWER:-$(git config kit.reviewer || echo claude)}"
[ "$engine" = off ] && { echo "review: off"; exit 0; }
[ "$engine" = claude ] || { echo "review: unknown REVIEWER '$engine' (use claude or off)" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "review: claude not installed" >&2; exit 1; }

if ! git diff --name-only "$base" "$head" | grep -qvE '(\.md|\.txt)$|^docs/'; then
  echo "review: docs-only change, skipped"; touch "$cache/$head.pass"; exit 0
fi

diff="$(git diff --no-color -M "$base" "$head" -- . \
  ':(exclude)package-lock.json' ':(exclude)pnpm-lock.yaml' ':(exclude)yarn.lock' ':(exclude)*.lock')"
[ -z "$diff" ] && { echo "review: no reviewable changes"; exit 0; }
max="${REVIEW_MAX_BYTES:-150000}"
note=""
if [ "${#diff}" -gt "$max" ]; then
  diff="${diff:0:$max}"
  note="The diff was cut off at $max bytes; say so in your report and review what you have."
fi

prompt="You are an independent code reviewer. You did not write this change, you have no stake in it,
and you have not seen the plan or the author's reasoning. Judge only what the diff does.
You may read files in the repository for context. Do not modify anything.

Look for: bugs and broken logic, security holes (injection, auth, unsafe input handling),
secrets or credentials, data loss, missing error handling on paths that can fail,
and tests that don't actually test anything. Ignore style, naming and formatting.

Report each finding as: file:line — blocker|major|minor — problem — fix
Use blocker only for changes that would break the build, corrupt or lose data, leak a secret,
or open a security hole. $note

End with exactly one line: VERDICT: BLOCK if there is at least one blocker, otherwise VERDICT: PASS"

out="$cache/$head.md"; err="$cache/$head.err"
payload="$(printf '%s\n\n<diff>\n%s\n</diff>\n' "$prompt" "$diff")"
# Use the Pro/Max login, never API billing: in -p mode a set ANTHROPIC_API_KEY always wins over the login.
printf '%s' "$payload" | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
  claude -p --model "${REVIEW_MODEL:-sonnet}" --no-session-persistence \
  --allowedTools "Read,Grep,Glob" --permission-mode dontAsk >"$out" 2>"$err" || true

verdict="$(grep -Eo 'VERDICT: *(PASS|BLOCK)' "$out" 2>/dev/null | tail -n1 || true)"
case "$verdict" in
  *PASS)  touch "$cache/$head.pass"; echo "review ($engine): PASS"; grep -E '— (major|minor) —' "$out" || true ;;
  *BLOCK) cat "$out"; echo; echo "review ($engine): BLOCK — fix the blockers above and push again. Full report: $out" >&2; exit 1 ;;
  *)      echo "review ($engine): the reviewer didn't return a verdict, so the push is stopped." >&2
          echo "  Check Claude Code is signed in (run claude, then /status) and you're not out of Pro usage. Error log: $err" >&2
          echo "  To push anyway this once: SKIP_REVIEW=1 git push" >&2; exit 1 ;;
esac
SH

  cat > "$proj/.github/workflows/greenlight.yml" <<YML
# agent-kit green light: both jobs must pass before a pull request can merge into the protected branch.
name: greenlight
on:
  push:
    branches: [main, master]
  pull_request:
permissions:
  contents: read
jobs:
  gitleaks:
    name: gitleaks
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Scan full history for secrets
        run: |
          curl -sSfL https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz | tar xz gitleaks
          ./gitleaks git --no-banner --redact -v .
  verify:
    name: verify
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run scripts/verify.sh
        run: bash scripts/verify.sh
YML

  chmod +x "$proj/.githooks/pre-commit" "$proj/.githooks/pre-push" "$proj/scripts/verify.sh" "$proj/scripts/independent-review.sh"

  # keep the obvious secret files out of git in the first place
  local ig="$proj/.gitignore" pat
  touch "$ig"
  for pat in .env .env.* '!.env.example' '*.pem' '*.key' node_modules/ __pycache__/ .DS_Store; do
    grep -qxF -- "$pat" "$ig" || echo "$pat" >> "$ig"
  done
}

ensure_gitleaks() {
  command -v gitleaks >/dev/null 2>&1 && return 0
  if command -v brew >/dev/null 2>&1; then
    say "installing gitleaks with Homebrew"
    brew install gitleaks && return 0
  fi
  warn "gitleaks is not installed — commits and pushes in this project will be blocked until it is."
  warn "install it: brew install gitleaks, or download v$GITLEAKS_VERSION from https://github.com/gitleaks/gitleaks/releases"
}

protect_branch() { # owner/repo branch
  local slug="$1" branch="$2" body
  body='{"required_status_checks":{"strict":false,"contexts":["gitleaks","verify"]},"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}'
  if printf '%s' "$body" | gh api -X PUT "repos/$slug/branches/$branch/protection" --input - >/dev/null 2>"${TMPDIR:-/tmp}/kit-protect.err"; then
    say "branch protection on $branch: gitleaks and verify must be green before a PR can merge"
  else
    warn "couldn't turn on branch protection: $(head -c 300 "${TMPDIR:-/tmp}/kit-protect.err")"
    warn "private repos on a free GitHub plan can't use branch protection — make the repo public or upgrade, then re-run: $0 repo <path>"
    warn "the local hooks still gate every commit and push either way."
  fi
}

cmd_repo() {
  [ $# -ge 1 ] || die "usage: $0 repo <path> [--public] [--no-github] [--name NAME]"
  local proj="$1"; shift
  local visibility="--private" github=1 name="" a
  while [ $# -gt 0 ]; do
    case "$1" in
      --public) visibility="--public" ;;
      --no-github) github=0 ;;
      --name) shift; name="${1:-}"; [ -n "$name" ] || die "--name needs a value" ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  need git "install git"
  mkdir -p "$proj"; proj="$(cd "$proj" && pwd)"
  [ -n "$name" ] || name="$(basename "$proj")"

  if [ ! -d "$proj/.git" ]; then
    say "git init (branch main)"
    git -C "$proj" init -q -b main
  fi

  say "writing gates: .githooks/, scripts/verify.sh, scripts/independent-review.sh, .github/workflows/greenlight.yml"
  write_gates "$proj"
  git -C "$proj" config core.hooksPath .githooks
  ensure_gitleaks

  if ! grep -q "agent-kit:gates" "$proj/AGENTS.md" 2>/dev/null; then
    cat >> "$proj/AGENTS.md" <<'MD'

<!-- agent-kit:gates -->
## Green light before every push
- Green light = `scripts/verify.sh` passes. Run it before saying a task is done.
- Never commit secrets, `.env` files or keys; gitleaks blocks commits and pushes that contain them.
- Every push goes through an independent reviewer (`scripts/independent-review.sh`). If it blocks, fix the findings. Never bypass a hook with `--no-verify` or `SKIP_*` unless the user explicitly says to.
MD
  fi

  git -C "$proj" add -A
  if ! git -C "$proj" rev-parse -q --verify HEAD >/dev/null; then
    say "first commit"
    git -C "$proj" commit -qm "chore: project scaffold with green-light gates" || die "first commit failed (the gitleaks pre-commit hook may have blocked it — see above)"
  elif ! git -C "$proj" diff --cached --quiet; then
    git -C "$proj" commit -qm "chore: agent-kit setup" || die "commit failed (see above)"
  fi

  [ "$github" = 1 ] || { say "done (local only). Push later with: $0 repo $proj"; return 0; }

  need gh "install the GitHub CLI (https://cli.github.com) and run: gh auth login"
  gh auth status >/dev/null 2>&1 || die "GitHub CLI isn't signed in — run: gh auth login"
  local branch slug
  branch="$(git -C "$proj" branch --show-current)"
  if git -C "$proj" remote get-url origin >/dev/null 2>&1; then
    say "origin already set — pushing $branch"
    (cd "$proj" && git push -u origin "$branch")
  else
    say "creating GitHub repo $name (${visibility#--})"
    # the scaffold is the kit's own files, so skip the AI review for this one push; gitleaks and verify still run
    (cd "$proj" && SKIP_REVIEW=1 gh repo create "$name" "$visibility" --source=. --remote=origin --push)
  fi
  slug="$(cd "$proj" && gh repo view --json nameWithOwner -q .nameWithOwner)"
  protect_branch "$slug" "$branch"
  say "done: https://github.com/$slug"
}

cmd_new() {
  [ $# -ge 1 ] || die "usage: $0 new <path> [design] [code] [--graph] [--no-memory] [--public] [--no-github] [--name NAME]"
  local proj="$1"; shift
  local p_args=() r_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      design|code|--graph|--no-memory) p_args+=("$1") ;;
      --public|--no-github) r_args+=("$1") ;;
      --name) r_args+=("$1" "${2:-}"); shift ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  mkdir -p "$proj"
  cmd_repo "$proj" --no-github           # git + gates first, so the project step commits into a gated repo
  cmd_project "$proj" "${p_args[@]+"${p_args[@]}"}"
  cmd_repo "$proj" "${r_args[@]+"${r_args[@]}"}"
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

# ---------------------------------------------------------------- basic memory
ensure_uv() {
  command -v uvx >/dev/null 2>&1 && return 0
  if command -v brew >/dev/null 2>&1; then
    say "installing uv with Homebrew (Basic Memory runs through it)"
    brew install uv && return 0
  fi
  warn "uv is not installed, so Basic Memory can't run yet."
  warn "install it: curl -LsSf https://astral.sh/uv/install.sh | sh   (or see https://docs.astral.sh/uv/)"
  warn "then re-run: $0 project <path> ... to finish the Basic Memory setup"
  return 1
}

setup_basic_memory() { # project-dir
  local proj="$1" name dir
  # one Basic Memory project per code project; notes live outside the repo, as plain Markdown
  name="$(basename "$proj" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-')"
  dir="$BM_HOME/$name"

  # MCP server, scoped to this project's notes. Committed, so the project carries it.
  python3 - "$proj/.mcp.json" "$name" <<'PY'
import json, os, sys
p, name = sys.argv[1], sys.argv[2]
s = json.load(open(p)) if os.path.exists(p) else {}
s.setdefault("mcpServers", {})["basic-memory"] = {"command": "uvx", "args": ["basic-memory", "mcp", "--project", name]}
json.dump(s, open(p, "w"), indent=2); open(p, "a").write("\n")
PY

  ensure_uv || return 0

  if uvx basic-memory project info "$name" >/dev/null 2>&1; then
    say "Basic Memory project '$name' already exists"
  else
    say "creating Basic Memory project '$name' at $dir"
    mkdir -p "$dir"
    uvx basic-memory project add "$name" "$dir" >/dev/null || warn "couldn't create the Basic Memory project — run: uvx basic-memory project add $name $dir"
  fi

  if grep -q '"basic-memory@basicmachines-co"' "$proj/.claude/settings.json" 2>/dev/null; then
    say "Basic Memory plugin already enabled"
  else
    say "installing the Basic Memory plugin (session-start briefing, save before compaction)"
    (cd "$proj" && uvx basic-memory install claude-code --scope project --yes >/dev/null) \
      || warn "Basic Memory plugin install failed — run inside the project: uvx basic-memory install claude-code --scope project"
  fi
  say "Basic Memory ready: notes in $dir. Open Claude Code there, approve the basic-memory server when asked, then run /basic-memory:bm-setup once."
}

cmd_project() {
  [ $# -ge 1 ] || die "usage: $0 project <path> [design] [code] [--graph] [--no-memory]"
  local proj="$1"; shift
  local packs=("kit-core") graph=0 memory=1 a
  for a in "$@"; do
    case "$a" in
      design) packs+=("kit-design") ;;
      code)   packs+=("kit-code") ;;
      --graph) graph=1 ;;
      --no-memory) memory=0 ;;
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

  # 4. AGENTS.md holds the rules every agent shares; CLAUDE.md imports it (other tools can read it later)
  if ! grep -q "agent-kit:rules" "$proj/AGENTS.md" 2>/dev/null; then
    {
      printf '<!-- agent-kit:rules -->\n# Agent rules\n'
      [ "$memory" = 1 ] && \
        printf -- '- Before starting, search Basic Memory for earlier decisions about this project; when you finish, record any new decision there.\n'
      printf -- '- Prefer code that already exists in the repo and the standard library over new dependencies.\n'
      printf -- '- Say what you verified and how (commands run and their result) before calling a task done.\n'
    } > "$proj/AGENTS.md.kit"
    [ -f "$proj/AGENTS.md" ] && cat "$proj/AGENTS.md" >> "$proj/AGENTS.md.kit"
    mv "$proj/AGENTS.md.kit" "$proj/AGENTS.md"
  fi
  touch "$proj/CLAUDE.md"
  if ! grep -qx '@AGENTS.md' "$proj/CLAUDE.md"; then
    { echo '@AGENTS.md'; cat "$proj/CLAUDE.md"; } > "$proj/CLAUDE.md.kit" && mv "$proj/CLAUDE.md.kit" "$proj/CLAUDE.md"
  fi

  # 5. Basic Memory: its own notes project, the MCP server, and the plugin's session hooks
  [ "$memory" = 1 ] && setup_basic_memory "$proj"

  # 6. short routing note — CLAUDE.md is loaded every turn, so keep it tiny
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

  # 7. optional codebase graph (only worth it on large repos)
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

  say "done. Commit .claude/, .mcp.json, AGENTS.md and CLAUDE.md. Then open Claude Code there and run /context."
}

cmd_doctor() {
  local scan=0
  [ "${1:-}" = "--scan" ] && scan=1
  check_prereqs
  claude plugin list
  for p in kit-core kit-design kit-code; do
    echo; say "$p"; claude plugin details "$p@$KIT_NAME" 2>/dev/null || echo "   not installed here"
  done

  # dependencies bring whole upstream plugins with them; this shows what each one costs every turn
  echo; say "skills per installed plugin (descriptions load every turn; manual-only skills don't)"
  python3 - "$HOME/.claude/plugins/cache" <<'PY'
import os, re, sys, collections
root = sys.argv[1]  # installed plugins only; marketplaces/ holds catalogs, which cost nothing
count, chars, manual, names = collections.Counter(), collections.Counter(), collections.Counter(), collections.defaultdict(set)
for d, _, files in os.walk(root):
    if "SKILL.md" not in files:
        continue
    parts = os.path.relpath(d, root).split(os.sep)
    key = "/".join(parts[:2])
    fm = re.match(r"^---\n(.*?)\n---", open(os.path.join(d, "SKILL.md"), errors="ignore").read(), re.S)
    meta = fm.group(1) if fm else ""
    if re.search(r"^disable-model-invocation:\s*true", meta, re.M):
        manual[key] += 1
        continue
    count[key] += 1
    chars[key] += len(meta)
    names[os.path.basename(d)].add(key)
if not count and not manual:
    print("   no plugin skills found under", root)
for k, n in count.most_common():
    extra = f"  (+{manual[k]} manual)" if manual[k] else ""
    print(f"   {k:<40} {n:>3} skills  ~{chars[k] // 4:>5} tokens/turn{extra}")
print(f"   {'total':<40} {sum(count.values()):>3} skills  ~{sum(chars.values()) // 4:>5} tokens/turn")
same = sorted(n for n, ks in names.items() if len(ks) > 1)
if same:
    print("   same skill name in more than one plugin (can confuse triggering):", ", ".join(same))
PY

  if [ "$scan" = 1 ]; then
    need npx "install Node.js 20+"
    echo; say "AgentShield security scan of this folder's agent config"
    npx -y ecc-agentshield scan . || warn "AgentShield reported issues (see above)"
  else
    echo; say "for a security scan of CLAUDE.md, settings, MCP config, hooks and skills: $0 doctor --scan"
  fi
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    init) cmd_init "$@" ;;
    sync) cmd_sync "$@" ;;
    register) cmd_register "$@" ;;
    project) cmd_project "$@" ;;
    repo) cmd_repo "$@" ;;
    new) cmd_new "$@" ;;
    doctor) cmd_doctor "$@" ;;
    *) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0" ;;
  esac
}
main "$@"
