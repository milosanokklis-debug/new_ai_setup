#!/usr/bin/env bash
# Lints plugins/*/skills/*/SKILL.md: frontmatter with name (= folder) and description, and at most
# 500 lines (hard fail for the kit's own skills, warning for those listed in VENDORED.md).
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

lint_skills() { # root -> prints FAIL:/WARN: lines, returns 1 if any FAIL
  local root="$1" bad=0 f dir name fm lines
  local vendored; vendored="$(awk -F'|' '/^\| /{gsub(/ /,"",$2); if ($2!="Skill" && $2!~/^-+$/) print $2}' "$root/VENDORED.md" 2>/dev/null || true)"
  for f in "$root"/plugins/*/skills/*/SKILL.md; do
    [ -e "$f" ] || continue
    dir="$(basename "$(dirname "$f")")"
    if [ "$(sed -n 1p "$f")" != "---" ]; then echo "FAIL: $f: no YAML frontmatter"; bad=1; continue; fi
    fm="$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$f")"
    name="$(sed -n 's/^name:[[:space:]]*//p' <<<"$fm" | head -n1 | tr -d '"'"'"'\r ')"
    [ -n "$name" ] || { echo "FAIL: $f: missing name"; bad=1; }
    if ! grep -q '^description:' <<<"$fm"; then echo "FAIL: $f: missing description"; bad=1
    elif [ -z "$(awk '/^description:/{sub(/^description:[[:space:]]*/,""); sub(/^[>|][-+]?[[:space:]]*$/,""); if ($0!=""){print "x"; exit}; d=1; next} d&&/^[[:space:]]+[^[:space:]]/{print "x"; exit} d&&/^[^[:space:]]/{exit}' <<<"$fm")" ]; then
      echo "FAIL: $f: empty description"; bad=1
    fi
    [ -z "$name" ] || [ "$name" = "$dir" ] || { echo "FAIL: $f: name '$name' != folder '$dir'"; bad=1; }
    lines="$(wc -l < "$f")"
    if [ "$lines" -gt 500 ]; then
      if grep -qx "$dir" <<<"$vendored"; then echo "WARN: $f: $lines lines (vendored, over 500)"
      else echo "FAIL: $f: $lines lines, over 500"; bad=1; fi
    fi
  done
  return $bad
}

# bad fixture: no description, empty description, and an own skill over 500 lines
mkdir -p "$tmp/plugins/p/skills/nodesc" "$tmp/plugins/p/skills/long"
printf -- '---\nname: nodesc\n---\n# x\n' > "$tmp/plugins/p/skills/nodesc/SKILL.md"
mkdir -p "$tmp/plugins/p/skills/emptydesc"
printf -- '---\nname: emptydesc\ndescription:\n---\n# x\n' > "$tmp/plugins/p/skills/emptydesc/SKILL.md"
{ printf -- '---\nname: long\ndescription: too long\n---\n'; seq 1 600; } > "$tmp/plugins/p/skills/long/SKILL.md"
rc=0; out="$(lint_skills "$tmp" 2>&1)" || rc=$?
[ "$rc" = 1 ] && grep -q 'missing description' <<<"$out" && grep -q 'over 500' <<<"$out" && grep -q 'emptydesc/SKILL.md: empty description' <<<"$out" \
  || { echo "FAIL: bad fixture did not fail as expected (rc=$rc)"; echo "$out"; exit 1; }

# real repo
rc=0; out="$(lint_skills "$kit" 2>&1)" || rc=$?
[ -z "$out" ] || echo "$out"
[ "$rc" = 0 ] || { echo "FAIL: skill lint failed on the repo"; exit 1; }
echo "OK: skills lint"
