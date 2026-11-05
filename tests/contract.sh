#!/usr/bin/env bash
# Contract tests for `agent-kit.sh ensure <path> [design] [code] --json`.
# Every case starts from a fresh `git init` fixture with one commit, under a scratch dir in ${TMPDIR:-/tmp}.
# Needs: bash, git, python3, and the `claude` CLI (plugin commands may need login and network; without
# `claude` the ensure cases print SKIP, never PASS). Case 12 (agent tool lists) needs nothing.
#
# Select cases: `tests/contract.sh --cases 8,10,11,12` or CONTRACT_CASES=8,10,11,12 (default: all).
# CI policy: no subscription token or other secret ever goes into GitHub Actions (public repo). Hosted CI runs
# only the offline subset 8,10,11,12, which never calls `claude plugin` (cases 4 and 6 need a successful
# ensure, which runs `claude plugin`, so they are not in the hosted subset). The rest run locally or on a
# self-hosted runner where `claude` is already logged in.
# Case 12 extra: if BM_TOOLS_FILE (one Basic Memory tool name per line) is set, every
# mcp__basic-memory__<tool> named in plugins/*/agents/*.md must be listed there; unset => SKIP for that check.
# Pinned versions are in .versions (CLAUDE_CODE_VERSION, BASIC_MEMORY_VERSION); a different local claude only warns.
#
# Claude user state lives in an isolated HOME (mktemp -d) so the test never touches ~/.claude.
# Set CONTRACT_REAL_HOME=1 to use your real HOME instead (needed if plugin commands require your login).
# Case 13 always uses its own empty HOME, which has no MCP servers registered, so `claude mcp list`
# does not show basic-memory and ensure must report "memory":"missing" (and still exit 0).
set -uo pipefail
CASES="${CONTRACT_CASES:-all}"
while [ $# -gt 0 ]; do case "$1" in
  --cases) CASES="${2:?--cases needs a list like 8,10,11,12}"; shift 2;;
  --cases=*) CASES="${1#--cases=}"; shift;;
  *) echo "usage: $0 [--cases N,N,...]" >&2; exit 2;;
esac; done
want() { [ "$CASES" = all ] || case ",$CASES," in *",$1,"*) return 0;; *) return 1;; esac; }
KIT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/contract.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
if [ "${CONTRACT_REAL_HOME:-0}" = 1 ]; then USER_HOME="$HOME"; else USER_HOME="$WORK/home"; mkdir -p "$USER_HOME"; fi
export HOME="$USER_HOME" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
OUT="$WORK/out"; ERR="$WORK/err"; RC=0
ENSURE_ENV=()          # extra args for env(1), e.g. -u KIT_REPO or HTTPS_PROXY=...
FIXTURES=()            # "dir:head" for cases 10/11
CASE_FAIL=0; TOTAL_FAIL=0; HIST_FAIL=0; MCP_FAIL=0

have_claude() { command -v claude >/dev/null 2>&1; }
fail() { echo "  - $*"; CASE_FAIL=1; }

# fixture NAME [CLAUDE.md text] [settings.json text]: fresh git repo with one commit; sets FX (no subshell, so FIXTURES is kept)
fixture() {
  local d="$WORK/$1"; mkdir -p "$d"; git -C "$d" init -q
  printf 'fixture\n' > "$d/README.md"
  [ -n "${2:-}" ] && printf '%s' "$2" > "$d/CLAUDE.md"
  [ -n "${3:-}" ] && { mkdir -p "$d/.claude"; printf '%s' "$3" > "$d/.claude/settings.json"; }
  git -C "$d" add -A && git -C "$d" commit -qm init
  FIXTURES+=("$d:$(git -C "$d" rev-parse HEAD)")
  FX="$d"
}

# ensure KITDIR ARGS...: runs from the kit dir with stdin closed; sets RC, $OUT, $ERR
ensure() {
  local k="$1"; shift; RC=0
  ( cd "$k" && env KIT_REPO=.. "${ENSURE_ENV[@]}" timeout 120 ./agent-kit.sh ensure "$@" </dev/null >"$OUT" 2>"$ERR" ) || RC=$?
}
need_rc() { [ "$RC" = "$1" ] || { fail "exit $RC, expected $1 (stderr: $(tail -n 3 "$ERR" | tr '\n' ' '))"; return 1; }; }
# jcheck 'python expr over d' : d is the JSON object on the last stdout line
jcheck() {
  python3 -I -c 'import json,sys
d=json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
sys.exit(0 if eval(sys.argv[2]) else 1)' "$OUT" "$1" 2>/dev/null || { fail "JSON check failed: $1 (last line: $(tail -n1 "$OUT" | cut -c1-200))"; return 1; }
}
# only_allowed DIR: every changed/untracked path is one the contract allows
only_allowed() {
  local l p
  while IFS= read -r l; do p="${l:3}"
    case "$p" in .claude/settings.json|.claude/agent-kit.json|CLAUDE.md|.claude/skills/web-design-guidelines|.claude/skills/web-design-guidelines/*) ;;
      *) fail "unexpected changed path: $p";; esac
  done < <(git -C "$1" status --porcelain -uall)
}
# outside_block FILE: file text with the agent-kit marker block removed
outside_block() {
  python3 -I -c 'import re,sys
t=open(sys.argv[1]).read()
print(re.sub(r"<!-- agent-kit:start -->.*?<!-- agent-kit:end -->","",t,flags=re.S).rstrip())' "$1"
}
snapshot() { (cd "$1" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null; git status --porcelain); }

run_case() { # NUMBER LABEL FUNCTION
  want "$1" || return 0; set -- "$1  $2" "$3"
  CASE_FAIL=0; local rc=0; "$2" || rc=$?
  if [ "$rc" = 77 ]; then echo "SKIP $1"
  elif [ "$CASE_FAIL" = 0 ]; then echo "PASS $1"
  else echo "FAIL $1"; TOTAL_FAIL=$((TOTAL_FAIL+1)); fi
}
need_ensure_env() { have_claude || { echo "  (claude CLI not found)"; return 77; }; }

case1() {
  need_ensure_env || return 77; fixture fx; F="$FX"
  ensure "$KIT" "$F" --json
  need_rc 0 || return
  jcheck 'd["ok"] is True and d["changed"] is True and "kit-core" in d["installed"]' \
    && jcheck 'set(d)>={"ok","changed","kit_version","installed","updated","removed","files","memory"} and d["memory"] in ("connected","missing")'
  [ -f "$F/.claude/agent-kit.json" ] || fail "manifest .claude/agent-kit.json missing"
  only_allowed "$F"
}
case2() {
  need_ensure_env || return 77; [ -n "${F:-}" ] || { fail "needs case 1 fixture"; return; }
  local before; before="$(snapshot "$F")"
  ensure "$KIT" "$F" --json; need_rc 0 || return
  jcheck 'd["ok"] is True and d["changed"] is False'
  [ "$before" = "$(snapshot "$F")" ] || fail "project files changed on rerun"
}
case3() {
  need_ensure_env || return 77; local f; fixture fx3 $'# Mine\n'; f="$FX"
  ensure "$KIT" "$f" design --json; need_rc 0 || return
  [ -d "$f/.claude/skills/web-design-guidelines" ] || fail "design did not create web-design-guidelines skill"
  outside_block "$f/CLAUDE.md" > "$WORK/o1"
  ensure "$KIT" "$f" code --json; need_rc 0 || return
  jcheck '"kit-design" in d["removed"] and "kit-code" in d["installed"]'
  [ ! -e "$f/.claude/skills/web-design-guidelines" ] || fail "skill folder still present after switching to code"
  outside_block "$f/CLAUDE.md" > "$WORK/o2"; cmp -s "$WORK/o1" "$WORK/o2" || fail "CLAUDE.md changed outside the marker block"
  only_allowed "$f"
}
case4() {
  need_ensure_env || return 77
  local md=$'# My project\n\nKeep this text. Unicode: \xc3\xa9\n\n- item\n' st='{"permissions":{"allow":["Bash(ls)"]},"unrelated":{"a":[1,2]}}'
  local f; fixture fx4 "$md" "$st"; f="$FX"
  ensure "$KIT" "$f" --json; need_rc 0 || return
  python3 -I -c 'import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); k={"extraKnownMarketplaces","enabledPlugins"}
sys.exit(0 if {x:y for x,y in a.items() if x not in k}=={x:y for x,y in b.items() if x not in k} and "mcpServers" not in b else 1)' \
    <(printf '%s' "$st") "$f/.claude/settings.json" || fail "settings.json: unrelated keys changed (compared as parsed JSON; key order/format may legitimately differ)"
  [ "$(outside_block "$f/CLAUDE.md")" = "$(printf '%s' "$md" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')" ] || fail "CLAUDE.md text outside the marker block changed"
  grep -qF '<!-- agent-kit:start -->' "$f/CLAUDE.md" && grep -qF '<!-- agent-kit:end -->' "$f/CLAUDE.md" || fail "marker block missing"
  sed -n '/<!-- agent-kit:start -->/,/<!-- agent-kit:end -->/p' "$f/CLAUDE.md" | grep -v '^<!--' | grep -m1 . | grep -qi 'basic.memory' || fail "first block line is not the Basic Memory rule"
  only_allowed "$f"
}
case5() {
  need_ensure_env || return 77; local f k="$WORK/kit5"; fixture fx5; f="$FX"
  ensure "$KIT" "$f" --json; need_rc 0 || return
  cp -a "$KIT" "$k"; [ -d "$k/.git" ] || git -C "$k" init -q
  local old; old="$(sed -n 's/^KIT_VERSION="\([^"]*\)".*/\1/p' "$k/agent-kit.sh" | head -1)"
  sed -i "s/^KIT_VERSION=\"$old\"/KIT_VERSION=\"$old.99\"/" "$k/agent-kit.sh"
  sed -i "s/\"version\": *\"$old\"/\"version\": \"$old.99\"/" "$k"/plugins/*/.claude-plugin/plugin.json "$k/.claude-plugin/marketplace.json"
  ensure "$k" "$f" --json; need_rc 0 || return
  jcheck '"kit-core" in d["updated"] and d["changed"] is True'
}
case6() {
  need_ensure_env || return 77; local f; fixture fx6; f="$FX"
  ensure "$KIT" "$f" --json; need_rc 0 || return
  [ "$(wc -l < "$OUT")" = 1 ] || fail "stdout has $(wc -l < "$OUT") lines, expected exactly 1"
  jcheck 'True'
  ! LC_ALL=C grep -q $'\033' "$OUT" || fail "ESC byte in stdout"
  ! LC_ALL=C grep -q $'\033' "$ERR" || fail "ESC byte in stderr"
}
case7() {
  need_ensure_env || return 77; local f k="$WORK/kit7"; fixture fx7; f="$FX"
  cp -a "$KIT" "$k"; [ -d "$k/.git" ] || git -C "$k" init -q
  git -C "$k" remote remove origin 2>/dev/null; git -C "$k" remote add origin https://github.com/o/r.git
  ENSURE_ENV=(-u KIT_REPO -u KIT_NAME)
  # KIT_REPO is unset here, so the kit must derive "o/r" from origin
  RC=0; ( cd "$k" && env -u KIT_REPO -u KIT_NAME timeout 120 ./agent-kit.sh ensure "$f" --json </dev/null >"$OUT" 2>"$ERR" ) || RC=$?
  ENSURE_ENV=()
  need_rc 0 || return
  grep -q '"o/r"' "$f/.claude/settings.json" || fail "settings.json does not reference repo o/r derived from origin"
}
case8() {
  need_ensure_env || return 77; local f p; fixture fx8; f="$FX"; mkdir -p "$WORK/plain"
  local b1 b2 b3; b1="$(snapshot "$f")"; b2="$(snapshot "$WORK/plain")"
  ensure "$KIT" "$WORK/nope" --json; need_rc 2; [ ! -e "$WORK/nope" ] || fail "nonexistent path was created"
  ensure "$KIT" "$WORK/plain" --json; need_rc 2; [ "$b2" = "$(snapshot "$WORK/plain")" ] || fail "non-repo dir was written to"
  ensure "$KIT" "$f" bogus --json; need_rc 2; [ "$b1" = "$(snapshot "$f")" ] || fail "unknown pack wrote files"
}
case9() {
  need_ensure_env || return 77; [ -n "${F:-}" ] || { fail "needs case 1 fixture"; return; }
  # best effort: a dead proxy makes any fetch fail fast; the 120s timeout guards against hangs
  ENSURE_ENV=(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9)
  ensure "$KIT" "$F" --json; ENSURE_ENV=()
  case "$RC" in 0) jcheck 'd["ok"] is True';; 4) ;; 124) fail "hung past 120s";; *) fail "exit $RC, expected 0 (nothing to fetch) or 4 (marketplace failure)";; esac
}
case12() {
  [ -n "${BM_TOOLS_FILE:-}" ] || echo "  SKIP 12 basic-memory tool names exist on server (BM_TOOLS_FILE not set)"
  [ -z "${BM_TOOLS_FILE:-}" ] || [ -r "$BM_TOOLS_FILE" ] || { fail "BM_TOOLS_FILE not readable: $BM_TOOLS_FILE"; return; }
  local f; for f in "$KIT"/plugins/*/agents/*.md; do
    python3 -I - "$f" <<'PY' || { CASE_FAIL=1; continue; }
import re, sys
f = sys.argv[1]; name = f.rsplit("/", 1)[1][:-3]
lines = open(f).read().split("\n")
end = lines[1:].index("---") + 1 if lines[0] == "---" and "---" in lines[1:] else 0
tools = next((l for l in lines[1:end] if l.startswith("tools:")), None)
if tools is None: print(f"  - {name}: no explicit tools: line"); sys.exit(1)
bm = [t.strip() for t in tools[6:].split(",") if "mcp__basic-memory__" in t]
names = " ".join(bm)
write = re.search(r"(write|edit|move|delete)", names) or any(t.endswith("__*") for t in bm)
read = re.search(r"(search|read|list|find|context|recent)", names) or any(t.endswith("__*") for t in bm)
import os
tf = os.environ.get("BM_TOOLS_FILE")
if tf:
    have = {l.strip() for l in open(tf) if l.strip()}
    for t in (t.strip() for t in tools[6:].split(",")):
        if t.startswith("mcp__basic-memory__") and not t.endswith("__*") and t[19:] not in have:
            print(f"  - {name}: {t} not in BM_TOOLS_FILE"); sys.exit(1)
writers = {"coder", "designer"}
if name in writers:
    if not (write and read): print(f"  - {name}: needs basic-memory write/edit and read tools, has: {bm}"); sys.exit(1)
else:
    if re.search(r"(write|edit|move|delete)", names) or any(t.endswith("__*") for t in bm):
        print(f"  - {name}: must be basic-memory read-only, has: {bm}"); sys.exit(1)
    if not read: print(f"  - {name}: needs basic-memory read tools, has: {bm}"); sys.exit(1)
PY
  done
}
case14() { # lead agent and the sonnet default (offline: reads the generator and the kit's own generated agents)
  local l="$KIT/.claude/agents/lead.md"
  [ -f "$l" ] || { fail "$l missing (run ./agent-kit.sh self)"; return; }
  grep -q '^model: opus$' "$l" || fail "lead.md is not model: opus"
  grep -q '^tools:.*Agent(Explore, kit-code:runner)' "$l" || fail "lead.md can spawn more than Explore and runner"
  grep -q 'setdefault("model", "sonnet")' "$KIT/agent-kit.sh" || fail 'generator does not default to "model": "sonnet"'
  local g="$WORK/guard-gen.py" t ev
  sed -n "/orchestrator-guard.py\" <<'PY'/,/^PY\$/p" "$KIT/agent-kit.sh" | sed '1d;$d' >"$g"
  cmp -s "$g" "$KIT/plugins/kit-core/scripts/orchestrator-guard.py" || fail "generated guard differs from plugins/kit-core/scripts/orchestrator-guard.py"
  t="$(python3 -c 'import tempfile,os;print(os.path.realpath(tempfile.gettempdir()))')"
  ev() { printf '{"agent_type":"lead","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2" | python3 "$g"; }
  ev Write "$KIT/README.md" | grep -q '"deny"' || fail "guard allowed lead Write to a repo path"
  ev Write "$t/handoff-x.md" | grep -q '"deny"' && fail "guard denied lead Write to the handoff file"
  ev Write "handoff-x.md" | grep -q '"deny"' || fail "guard allowed lead Write to a relative path"
  ev Edit "$t/handoff-x.md" | grep -q '"deny"' || fail "guard allowed lead Edit"
  ev Write "$KIT/README.md" | grep -q 'handoff' || fail "deny reason does not mention handoff"
  printf '{"agent_type":"lead","tool_name":"Write","tool_input":"oops"}' | python3 "$g" | grep -q '"deny"' || fail "guard did not deny lead with non-dict tool_input"
  ! grep -q 'setdefault("model", "opusplan")' "$KIT/agent-kit.sh" || fail "generator still emits opusplan"
}
case15() { # supervisor agent, guard rules, kit_block routing (offline)
  local sp="$KIT/.claude/agents/supervisor.md" g="$WORK/guard-gen15.py" cwd="$KIT" ev blk
  [ -f "$sp" ] || { fail "$sp missing (run ./agent-kit.sh self)"; return; }
  grep -q '^model: opus$' "$sp" || fail "supervisor.md is not model: opus"
  grep -q '^tools:.*Agent(orchestrator, Explore, kit-code:runner)' "$sp" || fail "supervisor.md Agent() list is wrong"
  sed -n "/orchestrator-guard.py\" <<'PY'/,/^PY\$/p" "$KIT/agent-kit.sh" | sed '1d;$d' >"$g"
  ev() { # agent_type tool path [extra-json]
    printf '{"agent_type":"%s","cwd":"%s","tool_name":"%s","tool_input":{"file_path":"%s","command":"%s"}%s}' "$1" "$cwd" "$2" "$3" "${5:-}" "${4:-}" | env -u CLAUDE_PROJECT_DIR python3 "$g"; }
  ev orchestrator Write "$KIT/x.md" | grep -q '"deny"' || fail "guard allowed orchestrator Write (no agent_id)"
  ev orchestrator Write "$KIT/x.md" ',"agent_id":"a1"' | grep -q '"deny"' || fail "guard allowed orchestrator subagent Write (agent_id)"
  ev coder Write "$KIT/x.md" ',"agent_id":"a1"' | grep -q '"deny"' && fail "guard denied a kit subagent"
  ev supervisor Write "$cwd/docs/handoff/runs/x.md" | grep -q '"deny"' && fail "guard denied supervisor Write to the run file"
  ev supervisor Write "docs/handoff/runs/x.md" | grep -q '"deny"' || fail "guard allowed supervisor relative path"
  ev supervisor Write "$cwd/docs/handoff/runs/sub/x.md" | grep -q '"deny"' || fail "guard allowed supervisor nested path"
  ev supervisor Write "$cwd/README.md" | grep -q '"deny"' || fail "guard allowed supervisor Write outside runs"
  ev supervisor Edit "$cwd/docs/handoff/runs/x.md" | grep -q '"deny"' || fail "guard allowed supervisor Edit"
  ev supervisor Bash "" "" | grep -q '"deny"' || fail "guard allowed supervisor Bash"
  ev supervisor Write "$cwd/docs/handoff/runs/../x.md" | grep -q '"deny"' || fail "guard allowed supervisor traversal path"
  ev supervisor Write "$cwd/docs/handoff/runs/x.txt" | grep -q '"deny"' || fail "guard allowed supervisor non-.md name"
  ev supervisor MultiEdit "$cwd/docs/handoff/runs/x.md" | grep -q '"deny"' || fail "guard allowed supervisor MultiEdit"
  mkdir -p "$WORK/p15/docs/handoff" "$WORK/out15"; ln -sfn "$WORK/out15" "$WORK/p15/docs/handoff/runs"
  cwd="$WORK/p15" ev supervisor Write "$WORK/p15/docs/handoff/runs/x.md" | grep -q '"deny"' || fail "guard allowed supervisor symlinked runs dir"
  ev orchestrator Bash "" ',"agent_id":"a1"' "sed -i s/a/b/ f" | grep -q '"deny"' || fail "guard allowed supervised orchestrator sed -i"
  ev orchestrator Bash "" ',"agent_id":"a1"' "echo hi > f.txt" | grep -q '"deny"' || fail "guard allowed supervised orchestrator redirect"
  ev supervisor Bash "" "" | grep -q 'orchestrator' || fail "supervisor deny does not point at the orchestrator"
  blk="$(bash -c 'source <(sed -n "/^is_kit_dir()/,/^}/p;/^kit_block()/,/^}/p" "$1"); kit_block /tmp/x 0 1 1 1 0 a b c' _ "$KIT/agent-kit.sh" 2>/dev/null)"
  grep -q 'claude --agent supervisor' <<<"$blk" || fail "kit_block has no supervisor line"
  grep -q 'Between tasks' <<<"$blk" && fail "kit_block still has the standing Between tasks line"
  grep -q '/clear' <<<"$blk" && fail "kit_block still mentions /clear"
  return 0
}
case13() {
  need_ensure_env || return 77; local f h; fixture fx13; f="$FX"; h="$WORK/home13"; mkdir -p "$h"
  RC=0; ( cd "$KIT" && env HOME="$h" KIT_REPO=.. timeout 120 ./agent-kit.sh ensure "$f" --json </dev/null >"$OUT" 2>"$ERR" ) || RC=$?
  if [ "$RC" = 4 ] || [ "$RC" = 5 ]; then echo "  (exit $RC with an empty HOME: plugin commands need login/network; cannot test memory state here)"; return 77; fi
  need_rc 0 || return
  jcheck 'd["memory"]=="missing"'
}

PINNED_CC="$(sed -n 's/^CLAUDE_CODE_VERSION=//p' "$KIT/.versions" 2>/dev/null | head -1)"; PINNED_CC="${PINNED_CC:-2.1.317}"
have_claude && ! claude --version 2>/dev/null | grep -qF "$PINNED_CC" && echo "WARN claude differs from pinned $PINNED_CC (.versions)"
echo "contract tests: cases=$CASES kit=$KIT scratch=$WORK home=$HOME claude=$(command -v claude || echo none)"
run_case 1 "fresh ensure --json" case1
run_case 2 "rerun is a no-op" case2
run_case 3 "design then code switches packs" case3
run_case 4 "user content survives" case4
run_case 5 "version bump => kit-core updated" case5
run_case 6 "stdout is one JSON line, no ANSI" case6
run_case 7 "repo derived from origin" case7
run_case 8 "usage errors exit 2, write nothing" case8
run_case 9 "network blocked never hangs" case9
run_case 12 "agent basic-memory tool lists" case12
run_case 14 "lead.md and model sonnet generated" case14
run_case 15 "supervisor agent, guard and kit_block" case15
run_case 13 "basic-memory missing => memory:missing" case13

# 10: git history untouched in every fixture; 11: no .mcp.json / mcpServers anywhere
if ! want 10 && ! want 11; then :
elif [ "${#FIXTURES[@]}" = 0 ]; then echo "SKIP 10 git log unchanged (no fixtures ran)"; echo "SKIP 11 no .mcp.json / mcpServers (no fixtures ran)"
else
  for e in "${FIXTURES[@]}"; do d="${e%%:*}"; h="${e##*:}"
    [ "$(git -C "$d" rev-parse HEAD)" = "$h" ] && [ "$(git -C "$d" rev-list --all | wc -l)" = 1 ] || { echo "  - $d: git history changed"; HIST_FAIL=1; }
    if [ -e "$d/.mcp.json" ] || grep -rqs mcpServers "$d/.claude" "$d/CLAUDE.md" 2>/dev/null; then echo "  - $d: .mcp.json or mcpServers present"; MCP_FAIL=1; fi
  done
  if want 10; then if [ "$HIST_FAIL" = 0 ]; then echo "PASS 10 git log unchanged in ${#FIXTURES[@]} fixtures"; else echo "FAIL 10 git log unchanged"; fi; fi
  if want 11; then if [ "$MCP_FAIL" = 0 ]; then echo "PASS 11 no .mcp.json / mcpServers"; else echo "FAIL 11 no .mcp.json / mcpServers"; fi; fi
fi
[ "$TOTAL_FAIL" = 0 ] && [ "$HIST_FAIL" = 0 ] && [ "$MCP_FAIL" = 0 ] || { echo "contract tests FAILED"; exit 1; }
echo "contract tests done"
