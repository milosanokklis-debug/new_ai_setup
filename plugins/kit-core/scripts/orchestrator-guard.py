#!/usr/bin/env python3
"""agent-kit orchestrator guard (PreToolUse).

The orchestrator main session plans and delegates; coder/designer agents change files. This denies
file edits on the orchestrator's own thread: Edit/Write tools, and the common ways Bash writes files
(sed -i, perl -i, > redirects, tee, python/node scripts that write files). git, gh, tests and
read-only commands are untouched. It is a pattern match, so it is a guard rail, not a sandbox.
"""
import json
import os
import re
import sys
import tempfile

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
INTERPRETER = re.compile(r"\b(python3?|node|bun|deno|ruby)\b")
SCRIPT_WRITES = re.compile(
    r"""open\([^)]*['"][wax]b?\+?['"]|\.write_(text|bytes)\(|\b(writeFile|appendFile)(Sync)?\(|File\.write\(""")
SHELL_WRITES = [
    (re.compile(r"\bsed\s+(?:[^|;&\n]*\s)?(?:-[a-zA-Z]*i|--in-place)"), "sed -i"),
    (re.compile(r"\bperl\s+(?:[^|;&\n]*\s)?-[a-zA-Z]*i"), "perl -i"),
    (re.compile(r"\btee\s+(?:-a\s+)?(?!/dev/null)[^\s|;&]"), "tee to a file"),
    # > or >> to a file; not 2>/dev/null, >&2, 2>&1, =>, ->, or a comparison inside quotes
    (re.compile(r"(?<![0-9&<>=-])>>?(?!&|\s*/dev/null|=)"), "a > redirect to a file"),
]


def split_heredocs(cmd):
    """Return (command text without heredoc bodies, the heredoc bodies)."""
    lines, kept, bodies, i = cmd.split("\n"), [], [], 0
    while i < len(lines):
        line = lines[i]
        kept.append(line)
        i += 1
        for m in re.finditer(r"<<-?\s*(['\"]?)([A-Za-z_]\w*)\1", line):
            body = []
            while i < len(lines) and lines[i].strip() != m.group(2):
                body.append(lines[i])
                i += 1
            i += 1
            bodies.append("\n".join(body))
    return "\n".join(kept), "\n".join(bodies)


def bash_write(cmd):
    shell, _ = split_heredocs(cmd)
    shell = re.sub(r"'[^']*'|\"(?:\\.|[^\"\\])*\"", "''", shell)  # quoted text isn't shell syntax
    for pattern, name in SHELL_WRITES:
        if pattern.search(shell):
            return name
    if INTERPRETER.search(cmd) and SCRIPT_WRITES.search(cmd):
        return "a script that writes files"
    return None


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "deny",
                                             "permissionDecisionReason": reason}}))


HANDOFF_NAME = re.compile(r"^(zsl-)?handoff[\w.-]*\.md$")  # /zsl:handoff writes zsl-handoff-YYYYMMDD-slug.md


def lead_may_write(event):
    """lead may Write only the /zsl:handoff output: <temp dir>/[zsl-]handoff*.md, absolute path, directly in the temp dir."""
    raw = (event.get("tool_input") or {}).get("file_path", "")
    if not isinstance(raw, str) or not os.path.isabs(raw):
        return False
    path = os.path.realpath(raw)
    return (os.path.dirname(path) == os.path.realpath(tempfile.gettempdir())
            and bool(HANDOFF_NAME.match(os.path.basename(path))))


def main():
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return
    if event.get("agent_id"):
        return
    agent = event.get("agent_type")
    if agent == "lead":
        # defense in depth next to the agent's tools list: lead may use Write, and only for the handoff file
        if event.get("tool_name") != "Write" or not lead_may_write(event):
            deny("lead can write only the handoff file (/zsl:handoff output in the temp directory), nothing else "
                 f"(blocked: {event.get('tool_name')}). Send the change back to the orchestrator: claude --agent orchestrator")
        return
    if agent != "orchestrator":
        return
    tool = event.get("tool_name", "")
    what = tool if tool in EDIT_TOOLS else None
    if tool == "Bash":
        what = bash_write((event.get("tool_input") or {}).get("command", ""))
    if not what:
        return
    reason = (f"The orchestrator doesn't change files itself (blocked: {what}). Delegate the change to "
              "kit-code:coder (code, tests, config, docs) or kit-design:designer (anything users see). "
              "If the user wants to work hands-on, they can restart with: claude --agent solo")
    deny(reason)


if __name__ == "__main__":
    main()
