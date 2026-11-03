#!/usr/bin/env bash
# Release hygiene: (1) a change to plugins/ or .claude-plugin/marketplace.json must bump KIT_VERSION in agent-kit.sh;
# (2) every plugin.json and every local marketplace entry must carry exactly KIT_VERSION.
# Usage: tests/version-bump.sh [BASE]   BASE defaults to $BASE, then origin/main, then HEAD~1.
# Marketplace entries pointing at external sources (taste-skill, ...) keep their own upstream version and are not checked.
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"; cd "$kit"
fail=0; bad() { echo "FAIL: $*"; fail=1; }

want="$(sed -n 's/^KIT_VERSION="\([^"]*\)".*/\1/p' agent-kit.sh | head -1)"
[ -n "$want" ] || { echo "FAIL: no KIT_VERSION=\"...\" line in agent-kit.sh"; exit 1; }

# 2. every version equals KIT_VERSION
python3 -I - "$want" plugins/*/.claude-plugin/plugin.json <<'PY' || fail=1
import json, sys
want, bad = sys.argv[1], 0
def chk(label, got):
    global bad
    if got != want: print(f"FAIL: {label} version is {got!r}, KIT_VERSION is {want!r}"); bad = 1
for f in sys.argv[2:]: chk(f, json.load(open(f)).get("version"))
m = json.load(open(".claude-plugin/marketplace.json"))
chk("marketplace.json metadata", m.get("metadata", {}).get("version"))
for p in m["plugins"]:
    if isinstance(p.get("source"), str) and p["source"].startswith("./plugins/"):
        chk("marketplace.json plugin " + p["name"], p.get("version"))
sys.exit(bad)
PY

# 1. changed plugin files need a version bump
base="${1:-${BASE:-origin/main}}"
if ! git rev-parse --verify -q "$base^{commit}" >/dev/null; then base="HEAD~1"; fi
if ! git rev-parse --verify -q "$base^{commit}" >/dev/null; then
  echo "SKIP: no base ref to diff against (single commit); only the version-equality check ran"
else
  changed="$(git diff --name-only "$base...HEAD" -- plugins .claude-plugin/marketplace.json)"
  if [ -n "$changed" ]; then
    d="$(git diff "$base...HEAD" -U0 -- agent-kit.sh)"
    if grep -q '^+KIT_VERSION=' <<<"$d" && grep -q '^-KIT_VERSION=' <<<"$d"; then :; else
      bad "plugins/ or marketplace.json changed vs $base but KIT_VERSION did not:"; sed 's/^/  /' <<<"$changed"
    fi
  fi
fi
[ "$fail" = 0 ] && echo "PASS: all versions are $want and plugin changes (if any) bumped KIT_VERSION" || exit 1
